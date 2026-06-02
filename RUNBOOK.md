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
   - [6.2 Storing Credentials Safely with SealedSecrets](#62-storing-credentials-safely-with-sealedsecrets)
   - [6.3 Add the SealedSecrets Controller to the Repository](#63-add-the-sealedsecrets-controller-to-the-repository)
7. [Phase 3: Bootstrap Flux (GitOps)](#7-phase-3-bootstrap-flux-gitops)
   - [7.1 Post-Bootstrap: Seal the Database Credentials](#71-post-bootstrap-seal-the-database-credentials)
8. [Phase 4: Artifactory Deployment](#8-phase-4-artifactory-deployment)
9. [How GitOps Works Here](#9-how-gitops-works-here)
10. [Repository Structure](#10-repository-structure)
11. [File-by-File Reference](#11-file-by-file-reference)
12. [How the Files Relate to Each Other](#12-how-the-files-relate-to-each-other)
13. [Verification Commands](#13-verification-commands)
14. [Troubleshooting](#14-troubleshooting)
15. [Future: Image Tag Automation](#15-future-image-tag-automation)

---

## 1. What This Environment Is

This is a **GitOps lab** — a self-hosted Kubernetes cluster where the desired state of every application and piece of infrastructure is declared in YAML files in this git repository, and a tool called **Flux** watches the repository and automatically applies any changes to the cluster.

The core principle: **git is the single source of truth**. You never `kubectl apply` anything directly. Instead, you commit a change, push it, and Flux reconciles the cluster to match.

> **What does "reconcile" mean?** Flux continuously compares what the cluster looks like *right now* against what the YAML files say it *should* look like. If there's a difference, it fixes it. This is called reconciliation — bringing reality in line with the desired state.

This lab runs:
- **Flux v2.3.0** — the GitOps engine
- **MetalLB v0.15.3** — a software load balancer (explained fully in Section 5.5 and Section 10)
- **Artifactory OSS v107.133.12** — a self-hosted artifact registry for storing Docker images, Helm charts, and other packages

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

> **What is a control plane node vs a worker node?** Think of the control plane as the manager of the cluster. It doesn't run your applications — it runs the software that makes decisions: scheduling pods, tracking the state of everything, accepting API requests from you (via `kubectl`). Worker nodes are where your actual applications run. The control plane tells workers what to run, and workers report back their status.

> **What is a CNI?** CNI stands for Container Network Interface. It's a plugin that handles networking between pods. Without it, pods on the same node can't talk to pods on other nodes. Think of it as the wiring that connects all the containers together. There are many CNI plugins (Flannel, Calico, Cilium, OVN-Kubernetes) — they all do the same job in different ways.

> **What is a subnet?** A subnet is a range of IP addresses that are all on the same local network segment. The notation `192.168.56.0/24` means "all addresses from 192.168.56.0 to 192.168.56.255". The `/24` is a prefix length — it tells you how many of the 32 bits in the IP address are fixed (the "network" part) versus variable (the "host" part). All four nodes and the MetalLB IP pool are in this same subnet, which means they can talk to each other directly without needing a router.

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

**What each command does:**
- `kubeadm reset -f` — undoes everything `kubeadm join` did. Stops kubelet, removes the node from the cluster's records, and cleans up Kubernetes configuration files. The `-f` flag means "don't ask for confirmation".
- `rm -rf /etc/cni/net.d` — removes the CNI configuration files. If these are left behind, the new CNI install will conflict with the old config.
- `ip link delete flannel.1` — deletes the virtual network interface Flannel created. This is like unplugging a virtual network cable. The `2>/dev/null || true` means "if this fails because the interface doesn't exist, that's fine, continue anyway".
- `ip link delete cni0` — same idea: removes the virtual bridge device that the CNI created to connect containers together.
- `iptables -F ... -X` — flushes (clears) all iptables rules. `-F` flushes all rules in all chains, `-t nat -F` and `-t mangle -F` flush the NAT and mangle rule tables, and `-X` deletes any custom chains. Without this, Kubernetes's old routing rules would persist and interfere with the new cluster.

> **What is iptables?** `iptables` is the Linux kernel's built-in packet filtering and routing system. Think of it as a very programmable traffic cop sitting in the kernel that inspects every network packet and decides what to do with it: forward it on, drop it, modify it, redirect it to a different destination. Kubernetes makes heavy use of iptables to route traffic to the right pod when you access a Service IP.

### On the control plane node

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo ip link delete flannel.1 2>/dev/null || true
sudo ip link delete cni0 2>/dev/null || true
sudo iptables -F && sudo iptables -t nat -F && sudo iptables -t mangle -F && sudo iptables -X
rm -rf ~/.kube
```

The extra `rm -rf ~/.kube` removes your local kubeconfig — the file that tells `kubectl` where the cluster API server is and what credentials to use to connect. You'll regenerate this when you run `kubeadm init` again.

### Back up the SealedSecrets controller key

With SealedSecrets, the `artifactory-db-credentials` Secret *is* in git (as an encrypted SealedSecret) — you don't need to recreate it manually after a rebuild. However, the SealedSecrets **controller's private key** lives only in the cluster and is lost when you reset. Without it, the controller cannot decrypt the SealedSecret you committed to git, and Artifactory won't be able to start.

Back up the key before tearing down:

```bash
kubectl get secret \
  -n sealed-secrets \
  -l sealedsecrets.bitnami.com/sealed-secrets-key \
  -o yaml > ~/sealed-secrets-master-key-backup.yaml
```

> **What are you backing up here?** The SealedSecrets controller stores its private key as a Kubernetes Secret in its own namespace. This command fetches all secrets labelled as sealed-secrets keys and saves them to a YAML file on your laptop. **Keep this file very secure and do not commit it to git** — anyone with this file can decrypt every SealedSecret you've ever committed. After rebuilding the cluster and bootstrapping Flux, restore it before the controller processes any SealedSecrets (see [Section 7.1](#71-post-bootstrap-seal-the-database-credentials)). If you lose the key, you will need to re-seal all secrets using the new controller's key.

### Clean up Flux from GitHub

Flux creates a **deploy key** on your GitHub repo so it can pull over SSH. If you re-bootstrap, it regenerates this key. To avoid a conflict, delete the old one first:

> **What is a deploy key?** It's a special SSH public/private key pair. The public key is registered with GitHub, which then allows whoever holds the matching private key to pull from (and optionally push to) the repository. It's called a "deploy key" because it's intended for automated systems (like Flux) rather than human users. Flux stores the private key as a Kubernetes Secret inside the cluster — GitHub stores the public key. Together they allow Flux to authenticate to GitHub without a username and password.

> **What is SSH?** SSH (Secure Shell) is a protocol for encrypted communication between two computers. It's most commonly used for remote terminal access, but it's also widely used for securely fetching git repositories. The key pair mechanism means: the remote end (GitHub) holds a "lock" (public key), and only whoever holds the matching "key" (private key) can open it.

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

Kubernetes has a few hard requirements that Rocky Linux doesn't satisfy by default. This section prepares each node before Kubernetes is installed.

---

**Disable swap.**

```bash
sudo swapoff -a
# Make it permanent across reboots:
sudo sed -i '/\bswap\b/d' /etc/fstab
```

> **What is swap?** RAM is your computer's fast, short-term memory — it holds data that running programs are actively using. When RAM fills up, the operating system can use a portion of the hard disk as overflow "RAM". This disk area is called **swap** (or a swap partition/file). It's much slower than real RAM, but it prevents the system from running out of memory entirely.
>
> **Why does Kubernetes refuse to start if swap is on?** Kubernetes needs to be able to make precise, reliable decisions about how much memory each pod gets. It tells the kernel "this pod is allowed 512MB" and the kernel enforces that limit. When swap is enabled, the kernel can quietly let a process use more memory than its limit by spilling onto disk — this makes Kubernetes's memory accounting unpredictable and unreliable. By requiring swap to be off, Kubernetes guarantees that its memory limits are hard and accurate.
>
> `swapoff -a` turns off swap immediately (the `-a` means "all swap devices"). But this is temporary — it won't survive a reboot. The `sed` command edits `/etc/fstab` (the file that controls what gets mounted at boot) to permanently remove any swap entries, so swap stays off after reboots.

---

**Set SELinux to permissive.**

```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
```

> **What is SELinux?** SELinux (Security-Enhanced Linux) is a security system built into the Linux kernel. It goes beyond standard Linux file permissions by labelling every process, file, and network port with a security context, then enforcing a policy that says which processes are allowed to do what. For example, it can prevent a web server process from reading files it has no business reading, even if the file permissions would otherwise allow it.
>
> **What is the difference between `enforcing` and `permissive`?**
> - **Enforcing** mode: SELinux actively blocks anything that violates its policy and logs the violation.
> - **Permissive** mode: SELinux still logs violations, but it doesn't block anything. Everything still works — you're just getting a warning log.
>
> **Why set permissive for a lab?** Kubernetes and its components interact with the kernel in complex ways. Making SELinux happy with all of those interactions in a lab environment would require carefully writing and maintaining SELinux policy rules — a significant amount of work that distracts from learning Kubernetes itself. Permissive mode lets you get the cluster running while still seeing SELinux audit logs if you want to inspect them. In a production environment, you'd invest the time to write correct SELinux policies.
>
> `setenforce 0` switches to permissive immediately. The `sed` command updates the config file so it persists across reboots (`0` = permissive, `1` = enforcing).

---

**Disable the firewall.**

```bash
sudo systemctl disable --now firewalld
```

> **What is `firewalld`?** `firewalld` is a host-based firewall — software running on each individual machine that controls which network connections are allowed in and out. Think of it as a bouncer for network traffic: it has a list of allowed ports and services, and it drops anything that doesn't match.
>
> **Why does firewalld cause problems for Kubernetes?** A Kubernetes cluster relies on many different network connections between nodes — for example:
> - `etcd` (the cluster database) uses ports 2379–2380
> - The API server uses port 6443
> - `kubelet` uses port 10250
> - Flannel's VXLAN overlay uses UDP port 8472
>
> `firewalld`'s default rules would block most of these. You could configure it to allow each port individually, but for a lab on an isolated private network (these VMs can't be reached from the internet), it's far simpler and less error-prone to disable it entirely.
>
> `systemctl disable --now firewalld` does two things at once: `disable` prevents it from starting at boot, and `--now` also stops it immediately.

---

**Load kernel modules.**

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter
```

> **What is the Linux kernel?** The kernel is the core of the operating system. It's the software that sits directly on top of the hardware and manages everything: CPU scheduling, memory allocation, device drivers, and — critically for us — networking. When you run a program, it doesn't touch the hardware directly; it makes requests to the kernel.
>
> **What are kernel modules?** The kernel doesn't load every possible feature at startup — that would be wasteful. Instead, features are packaged as **modules** (sometimes called "loadable kernel modules" or LKMs): chunks of kernel code that can be loaded into the running kernel on demand and unloaded when no longer needed. Think of them like plugins for the kernel.
>
> The `modprobe` command loads a module into the running kernel right now. The file `/etc/modules-load.d/k8s.conf` tells the system to load these modules automatically at boot. Without both, the modules would need to be loaded manually after every reboot.

**The `overlay` module** — this is needed by containerd (the container runtime) to run containers efficiently.

> **What does `overlay` do?** Container images are built in layers — like a stack of transparent acetate sheets. The base image might be "Ubuntu 22.04", then on top of that is "Ubuntu 22.04 + Python 3", then on top of that is your actual application code. This layering is efficient because many containers can share the same base layers without duplicating the data on disk. The `overlay` filesystem driver is what allows the Linux kernel to present these stacked layers as a single unified filesystem to the process running inside the container. Without it, each container would need a full copy of all its files, wasting huge amounts of disk space.

**The `br_netfilter` module** — this is needed so that Kubernetes's packet routing works correctly when pods communicate.

> **What is a network bridge?** A network bridge is a virtual switch inside the kernel. When multiple containers on the same node need to communicate with each other, they're connected to a bridge — just like multiple computers plugging into a physical network switch. The kernel's bridge device forwards packets between containers based on their MAC addresses.
>
> **What is iptables again, and why does it need to see bridged traffic?** As explained above, `iptables` is the kernel's traffic cop — it intercepts packets and can route, drop, or modify them. Kubernetes uses iptables extensively to implement its Service abstraction: when you access a Service IP (like `10.96.0.1`), iptables secretly rewrites that to the actual IP of a backend pod. This is called **NAT** (Network Address Translation).
>
> Here's the problem: **by default, traffic flowing through a bridge bypasses iptables entirely.** The bridge handles it internally (switching based on MAC addresses) before iptables even gets a chance to see it. This means: when Pod A on Node 1 sends a packet to a Service IP, and that packet travels through the bridge to Pod B on the same node, iptables never sees the packet — so the Service IP never gets rewritten — so the connection fails.
>
> **What does `br_netfilter` do?** Loading this module tells the kernel: "even when a packet is being forwarded through a bridge, still send it through iptables first." It hooks bridge forwarding into the netfilter (iptables) framework. With this module loaded, every bridged packet passes through iptables, and Kubernetes's Service routing works correctly.

---

**Configure kernel networking settings:**

```bash
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

> **What is `sysctl`?** `sysctl` is a mechanism for reading and modifying kernel parameters at runtime — tunable knobs that control kernel behaviour. The settings live under `/proc/sys/` as virtual files. Writing to these files changes the kernel's behaviour immediately. The file `/etc/sysctl.d/k8s.conf` stores these settings so they're re-applied at every boot. `sysctl --system` reads all the sysctl config files and applies them right now.

**`net.bridge.bridge-nf-call-iptables = 1`** — this activates the behaviour that `br_netfilter` makes possible: it tells the kernel "yes, please route bridged IPv4 packets through iptables." Loading `br_netfilter` adds the *capability*, but this sysctl setting *enables* it. Without this set to `1`, loading `br_netfilter` has no effect and Kubernetes Service routing breaks completely.

**`net.bridge.bridge-nf-call-ip6tables = 1`** — the same setting but for IPv6 traffic. Even if you're not using IPv6, Kubernetes components may generate IPv6 bridge traffic internally, so it's good practice to enable this too.

**`net.ipv4.ip_forward = 1`** — this tells the kernel to act as a router: if a packet arrives on one network interface and its destination address belongs to a different network, forward it out through the appropriate other interface. By default, Linux does not do this — it simply drops packets that aren't destined for its own IP addresses. Kubernetes pods each have their own IP address on a virtual network, and for them to communicate with the outside world (and for external traffic to reach them), the node's kernel must forward packets between the pod network and the physical network interface. Without `ip_forward = 1`, pods are completely isolated from everything outside their node.

---

### 5.2 Install the Container Runtime (containerd)

Kubernetes doesn't run containers itself. It delegates to a **container runtime** — the software that actually creates and manages containers. This lab uses **containerd** — the same runtime used by Docker internally and by most managed Kubernetes services.

> **What is a container runtime?** A container runtime is the software that takes a container image (a packaged, self-contained bundle of an application and its dependencies) and actually runs it as a process on the host. It handles: unpacking the image layers, setting up the container's isolated filesystem (using the `overlay` module from above), creating the network namespace, enforcing resource limits, and starting the process inside. Kubernetes tells the container runtime "start this container with these settings" — the runtime figures out the low-level details.
>
> **OpenShift analogy:** containerd here is equivalent to CRI-O in OpenShift. Both implement the **Container Runtime Interface (CRI)** — a standard API that `kubelet` (the Kubernetes node agent) uses to talk to the container runtime. This separation means Kubernetes doesn't care which runtime you use, as long as it speaks CRI.

**Add the Docker repository** (containerd is distributed via Docker's repo):

```bash
sudo dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
```

**Install containerd:**

```bash
sudo dnf install -y containerd.io
```

**Configure containerd.** The default config has a critical problem: it uses the `cgroupfs` cgroup driver, but Kubernetes expects `systemd`. Mismatched drivers cause subtle, hard-to-debug failures.

```bash
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
```

> **What are cgroups?** `cgroups` (control groups) is a Linux kernel feature that lets you group processes together and apply resource limits to the whole group. For example: "this group of processes is allowed to use at most 2 CPU cores and 1GB of RAM." Kubernetes uses cgroups to enforce resource limits on pods — when you set `resources.limits.memory: 512Mi` in a pod spec, Kubernetes creates a cgroup for that pod's containers and tells the kernel to enforce a 512MB memory cap.
>
> **What is a cgroup driver?** There are two ways to interact with cgroups — two different "drivers" or interfaces. The old way, `cgroupfs`, involves directly reading and writing files in the `/sys/fs/cgroup/` filesystem. The new way, `systemd`, delegates cgroup management to `systemd` (the init system that manages all services on the machine). `systemd` itself uses cgroups to manage the services it runs, so if containerd and Kubernetes both try to manage cgroups directly via `cgroupfs`, they can fight with `systemd` over who controls what — leading to resource limit failures, pod evictions, or node instability. Using `systemd` as the cgroup driver for both means everything goes through one consistent manager.

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

> `systemctl enable` means "start this service automatically at boot". `--now` also starts it immediately without needing a separate `systemctl start` command.

---

### 5.3 Install kubeadm, kubelet, kubectl

These three tools are what actually make Kubernetes run on the node:

| Tool | What it does |
|---|---|
| `kubelet` | The agent that runs on every node. It talks to the API server and manages pod lifecycle. Think of it as the node's brain — it receives instructions ("run this container") and reports back status ("the container is running / crashed / etc."). |
| `kubeadm` | A one-shot installer. You use it to initialise the control plane and join workers. After setup, it's mostly idle — it's a setup tool, not a runtime component. |
| `kubectl` | Your CLI for talking to the cluster. It sends HTTP requests to the Kubernetes API server. Same tool you've always used. |

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

> **Why the `exclude=` line?** By default, `dnf` will upgrade any installed package when you run `dnf upgrade`. Without this exclusion, a routine system update could silently upgrade `kubelet`, `kubeadm`, and `kubectl` to the next minor version — which would be a problem because Kubernetes has strict version compatibility rules. The `exclude=` line tells `dnf` to never automatically upgrade these packages. You use `--disableexcludes=kubernetes` when you intentionally want to install or upgrade them.

**Install:**

```bash
sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
```

**Enable kubelet.** It won't fully start yet (it needs the cluster to exist), but enabling it now means it starts automatically after `kubeadm init` or `kubeadm join`:

```bash
sudo systemctl enable kubelet
```

> At this point, `kubelet` will start and quickly stop in a loop — this is normal. It's waiting for the cluster configuration that `kubeadm init` will provide. `systemctl enable` means it will start at boot, so once the cluster configuration arrives, it will stay running.

---

### 5.4 Initialise the Control Plane

> **Control plane node only (`cakers-cp-1`)**

This is the equivalent of running the OpenShift installer's control-plane phase. `kubeadm init` sets up everything that *is* the Kubernetes control plane — the cluster's brain.

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=192.168.56.10
```

**What these flags do:**

- `--pod-network-cidr=10.244.0.0/16` — declares the IP address range that pods will receive addresses from. A **CIDR** (Classless Inter-Domain Routing) notation like `10.244.0.0/16` describes a block of IP addresses: in this case, all addresses from `10.244.0.0` to `10.244.255.255` (65,536 addresses). This range is kept completely separate from your node IPs (`192.168.56.x`) — pods get addresses in the `10.244.x.x` range, and the CNI handles routing between them. The value `10.244.0.0/16` is specifically what Flannel (the CNI we install next) is preconfigured to expect — it must match.
- `--apiserver-advertise-address=192.168.56.10` — the IP address the API server listens on and tells other nodes to use when connecting. Use the control plane node's actual network IP (not `localhost` or `127.0.0.1`), or the worker nodes won't be able to reach it.

**What `kubeadm init` actually sets up:**

> - **API server** — the HTTP/HTTPS API that everything talks to. `kubectl` talks to it. Worker nodes talk to it. Flux talks to it. It's the single point of communication for the entire cluster — nothing changes in the cluster without going through the API server.
> - **etcd** — a distributed key-value database that stores all cluster state. Every object you create (pods, services, deployments, etc.) is stored here. It's the cluster's "memory" — if etcd is lost, the cluster's state is lost. Running `kubectl get pods` ultimately reads from etcd. Running `kubectl apply` ultimately writes to etcd.
> - **scheduler** — watches for newly created pods that don't have a node assigned yet, then picks the best node for each pod based on available resources, node labels, affinity rules, and other constraints. It's the decision-maker for "which node should this pod land on?"
> - **controller manager** — runs a collection of control loops (called "controllers") that continuously watch the cluster state and reconcile it toward the desired state. For example: the Deployment controller watches for Deployments and makes sure the right number of pods are running; if a pod crashes, the controller creates a new one. There are controllers for ReplicaSets, StatefulSets, Services, and many other resource types.

**This takes about 2 minutes.** At the end, the output contains two things you need:

1. **The `kubeadm join` command** — save this. You'll use it on each worker node. It looks like:
   ```
   kubeadm join 192.168.56.10:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
   ```
   > The `token` is a temporary credential the worker uses to authenticate with the control plane during joining. The `discovery-token-ca-cert-hash` is a fingerprint of the control plane's TLS certificate — the worker uses this to verify it's connecting to the *real* control plane and not an impostor. Port 6443 is where the Kubernetes API server listens.

2. **Instructions to copy your kubeconfig** — run these now on the control plane node:
   ```bash
   mkdir -p $HOME/.kube
   sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
   sudo chown $(id -u):$(id -g) $HOME/.kube/config
   ```
   > **What is a kubeconfig?** It's a YAML file (usually at `~/.kube/config`) that tells `kubectl` where the cluster's API server is, what certificate to use to authenticate, and which cluster/user context to use by default. Without it, `kubectl` doesn't know how to reach your cluster.

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

Without a CNI, pods cannot communicate with each other or with Services. This is why nodes show `NotReady` right after `kubeadm init` — the Kubernetes control plane is running, but the networking layer isn't wired up yet.

> **OpenShift analogy:** In OpenShift, OVN-Kubernetes is the CNI and it comes pre-installed. Here you pick one and install it yourself.

Install Flannel — the simplest CNI for a lab:

```bash
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

> **How does Flannel work?** Flannel creates a virtual **overlay network** — a network that tunnels on top of your existing physical network. Here's the problem it's solving: Pod A is on Node 1 with pod IP `10.244.1.5`, and Pod B is on Node 2 with pod IP `10.244.2.7`. Your physical network (the `192.168.56.x` subnet) has no idea what to do with a packet destined for `10.244.1.5` — those aren't real IPs from the physical network's perspective.
>
> Flannel solves this using **VXLAN** (Virtual eXtensible LAN): it wraps ("encapsulates") the pod-to-pod packet inside a UDP packet that the physical network *can* route. So a packet going from Pod A to Pod B actually travels as: [physical: Node1→Node2 via 192.168.56.x] [inside: pod IP packet 10.244.1.5→10.244.2.7]. On arrival at Node 2, Flannel unwraps the outer packet and delivers the inner pod-IP packet to Pod B. This all happens transparently — the pods themselves just see normal IP connectivity.
>
> Flannel creates a `flannel.1` virtual network interface on each node (that's the tunnel endpoint) and uses the `10.244.0.0/16` CIDR you specified in `kubeadm init` to allocate a `/24` sub-range to each node (e.g. Node 1 gets `10.244.1.0/24`, Node 2 gets `10.244.2.0/24`).

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

Run this on each worker. It takes 30–60 seconds per node. The node downloads its configuration from the control plane, starts `kubelet`, and registers itself with the API server. Once registered, the scheduler can start placing pods on it.

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

> **What is a namespace?** Namespaces are a way to partition a Kubernetes cluster into virtual sub-clusters. All the core Kubernetes components (the API server helper pods, the scheduler, etcd, the CNI, etc.) run in a namespace called `kube-system`. Your applications can run in separate namespaces (e.g., `artifactory`). This separation prevents name collisions and makes it easy to apply different access controls to different teams or applications. The `-n kube-system` flag on `kubectl` commands means "look in the `kube-system` namespace".

You now have a working Kubernetes cluster. On to Phase 2.

---

## 6. Phase 2: Prepare Nodes for Applications

### 6.1 Create hostPath directories

Artifactory and PostgreSQL need **persistent storage** — storage that survives pod restarts, upgrades, and rescheduling. Unlike normal container filesystems (which are temporary and lost when a container stops), persistent storage must be backed by something durable.

Rather than setting up a dedicated storage provisioner (like Rook/Ceph or Longhorn), this lab uses **hostPath volumes** — directories on the worker node's local filesystem that pods mount directly. It's the simplest possible approach: the data lives in a regular folder on the host.

> **What is a PersistentVolume (PV)?** A PV is a Kubernetes object that represents a piece of storage that exists independently of any pod. It's the cluster administrator's way of saying "here is some storage, available for use." In this lab, each PV is backed by a `hostPath` directory.
>
> **What is a PersistentVolumeClaim (PVC)?** A PVC is a request for storage from an application. It says "I need 20Gi of storage with ReadWriteOnce access." Kubernetes matches PVCs to PVs: it finds a PV that satisfies the requirements and "binds" them together. Once bound, the pod mounts the PVC like a disk.
>
> **What does ReadWriteOnce mean?** It means the volume can be mounted by exactly one node at a time (though multiple pods on the same node can use it). Other access modes include ReadOnlyMany (many nodes, read-only) and ReadWriteMany (many nodes, read-write — requires special storage systems).

The directories must exist before Flux tries to deploy Artifactory, otherwise the PersistentVolumeClaims will be stuck in `Pending` and the pods will never start.

> **Run this on all worker nodes** (`cakers-worker-1`, `cakers-worker-2`, `cakers-worker-3`). The Kubernetes scheduler decides which node each pod lands on. Because the hostPath PVs have no `nodeAffinity` (a constraint that would force a pod to run on a specific node), you cannot predict which worker will be chosen. Creating the directories everywhere avoids a startup failure if the pod doesn't land where you expected.

```bash
sudo mkdir -p /mnt/data/artifactory-data
sudo mkdir -p /mnt/data/postgres-data
sudo chmod 777 /mnt/data/artifactory-data
sudo chmod 777 /mnt/data/postgres-data
```

> **Why `chmod 777`?** Linux file permissions control who can read, write, and execute files. `chmod 777` gives read, write, and execute permission to everyone — the owner, the group, and all other users. Artifactory and PostgreSQL run as specific non-root users inside the container (UID 1030 and UID 1001 respectively). These UIDs don't exist on the host machine, and the directories are owned by `root`. Rather than trying to `chown` the directories to UIDs that don't exist as named users on the host, `777` makes the directories writable by anyone — a pragmatic shortcut for a lab. In production, you'd use `chown 1030:1030` (using the UID directly) to give only the correct user write access.

---

### 6.2 Storing Credentials Safely with SealedSecrets

The Artifactory Helm chart includes a bundled PostgreSQL database. By default, the chart generates a **random password on every Helm install or upgrade**. Because Flux reconciles the HelmRelease on a regular interval (checking if the chart config matches what's in git and re-applying it if needed), this means the password in the cluster Secret gets silently replaced — while the on-disk PostgreSQL database still expects the original password. The result is `FATAL: password authentication failed` and every Artifactory sidecar crash-looping.

> **What is a Helm chart?** Helm is a package manager for Kubernetes — think of it like `apt` or `dnf` but for Kubernetes applications. A **chart** is a Helm package: a collection of YAML templates and default values that describe how to deploy an application. You can customise the deployment by overriding values. `helm install` renders the templates with your values and applies them to the cluster. `helm upgrade` updates an existing installation.
>
> **What is a Kubernetes Secret?** A Secret is a Kubernetes object for storing sensitive data — passwords, API keys, TLS certificates — separately from the application configuration. Secrets are base64-encoded (not encrypted at rest by default, but access can be restricted via RBAC). Applications can consume Secrets as environment variables or mounted files.
>
> **What is RBAC?** RBAC stands for Role-Based Access Control. It's how Kubernetes controls who is allowed to do what. You define Roles (a set of permissions, e.g., "can read Secrets in namespace X") and bind them to ServiceAccounts or users. Flux, for example, has a ServiceAccount with RBAC rules that allow it to create and modify resources across the cluster.

The fix is to use **fixed** credentials that you control and supply to the HelmRelease via `valuesFrom`. But this creates a challenge: you need to store those credentials somewhere safe. Putting plain passwords in a git repository — even a private one — is a security risk.

> **Why is a private git repo not safe for secrets?** Anything committed to git persists in the history forever. Even if you delete the file later, the password is still visible in the commit log. If the repository is ever made public, forked, backed up to a different system, or accessed via a developer's laptop that gets compromised, those credentials are exposed. Private repos also have access controls that can change — and many git hosting services' support staff have some level of read access. The rule of thumb: **never commit secrets to git in plain text.**

This is where **SealedSecrets** comes in. SealedSecrets is a tool made by Bitnami Labs that lets you store *encrypted* secrets in git. The setup has two parts:

- **The controller** — a program that runs inside your Kubernetes cluster. It holds a private key and uses it to decrypt secrets. It watches for `SealedSecret` objects and automatically creates the corresponding regular Kubernetes `Secret` objects that your applications read.
- **`kubeseal`** — a command-line tool you run on your laptop. It encrypts a plain Secret YAML file using the controller's *public* key (which is safe to share), producing a `SealedSecret` YAML file. Only the controller — the one holding the matching private key — can ever decrypt it.

> **What is a public/private key pair?** This is the foundation of **asymmetric encryption**. Unlike a shared password (where both sides need the same secret to lock and unlock), a key pair has two complementary keys: a **public key** (safe to share with anyone) and a **private key** (kept secret and never shared). Data encrypted with the public key can *only* be decrypted by the matching private key. Think of the public key as a padlock you give to everyone — they can lock boxes with it, but only you, holding the unique key that fits that padlock, can ever open them. SealedSecrets uses this: your laptop encrypts with the public key, but only the cluster controller can decrypt with the private key.

The result: you can commit the `SealedSecret` YAML to git without risk. Anyone who reads it sees only long strings of random-looking encrypted characters. Only your cluster's SealedSecrets controller can decrypt it back into the original secret.

Here is the overall flow once everything is set up:

```
1. Controller starts in the cluster → generates a public/private key pair automatically
2. You run `kubeseal --fetch-cert` to get the public key certificate from the controller
3. You write a regular Secret YAML on your laptop (never applied to the cluster directly)
4. You pipe that YAML through `kubeseal` → it produces a SealedSecret YAML with encrypted data
5. You commit the SealedSecret YAML to git (safe — it is just encrypted bytes)
6. Flux detects the new commit and applies the SealedSecret to the cluster
7. The controller sees the new SealedSecret, decrypts it with its private key
8. The controller creates a regular Kubernetes Secret in the cluster automatically
9. Artifactory reads the Secret as normal — it has no idea SealedSecrets is involved
```

Setting this up happens in two phases:

- **Section 6.3 (right now):** Add the SealedSecrets controller's Helm chart files to this git repository. The controller won't actually be installed yet — that happens when Flux bootstraps in Phase 3.
- **Section 7.1 (after Phase 3):** Once the controller is running in the cluster, install `kubeseal` on your laptop, encrypt the database credentials, and commit the result to git.

The HelmRelease in `apps/artifactory/helmrelease.yaml` references the credentials Secret via `valuesFrom` — see the [file reference](#appsartifactoryhelmreleaseyaml) for details on how that works.

---

### 6.3 Add the SealedSecrets Controller to the Repository

The SealedSecrets controller is installed via Helm, exactly like MetalLB. You add its configuration to the git repository now, before the Flux bootstrap, so that Flux installs it automatically as part of the `infra-controllers` layer in Phase 3.

> **Why does the SealedSecrets controller belong in `infrastructure/controllers/` alongside MetalLB?** The controller needs to be running *before* Flux tries to deploy Artifactory. This is because the `apps` layer applies both the `SealedSecret` (the encrypted credentials) and the Artifactory `HelmRelease` at roughly the same time. The SealedSecrets controller must be able to decrypt the SealedSecret and create the real `artifactory-db-credentials` Secret before (or very shortly before) the Helm controller tries to read it. Placing the SealedSecrets controller in `infrastructure/controllers/` — where `wait: true` and `dependsOn` ordering ensure the entire infra layer is healthy before the `apps` layer starts — guarantees this.

**Step 1 — Add the Helm repository source.**

This file tells Flux's source-controller where to find the SealedSecrets Helm chart (the equivalent of running `helm repo add`):

`infrastructure/repositories/sealed-secrets.yaml`:
```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata:
  name: sealed-secrets
  namespace: flux-system
spec:
  interval: 1h
  url: https://bitnami-labs.github.io/sealed-secrets
```

`infrastructure/repositories/kustomization.yaml` — add the new file to the list:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - jfrog.yaml
  - metallb.yaml
  - sealed-secrets.yaml
```

**Step 2 — Add the Helm release for the controller.**

`infrastructure/controllers/sealed-secrets/helmrelease.yaml`:
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: sealed-secrets
  namespace: sealed-secrets
spec:
  interval: 15m
  chart:
    spec:
      chart: sealed-secrets
      version: "2.16.1"
      sourceRef:
        kind: HelmRepository
        name: sealed-secrets
        namespace: flux-system
  install:
    createNamespace: true
  values:
    fullnameOverride: sealed-secrets-controller
```

> **What does `fullnameOverride` do?** By default, Helm names chart resources by combining the release name with the chart name — which can produce something unwieldy like `sealed-secrets-sealed-secrets`. The `fullnameOverride` value tells the chart to use exactly the string `sealed-secrets-controller` as the name for the controller's Deployment and Service instead. This matters because the `kubeseal` CLI tool (which you'll use in Section 7.1 to encrypt secrets) looks for a Service named `sealed-secrets-controller` by default. Setting this value means you can use `kubeseal` commands without any extra flags to specify where to find the controller.
>
> **What does `createNamespace: true` do?** It tells the Helm chart to create the `sealed-secrets` namespace automatically if it doesn't already exist. Unlike MetalLB (where we declared the namespace in a separate `namespace.yaml` file), the SealedSecrets controller has no CRDs and no dependent configs, so there's no need to give it its own namespace file. Helm creating the namespace is fine.

`infrastructure/controllers/sealed-secrets/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - helmrelease.yaml
```

`infrastructure/controllers/kustomization.yaml` — add the new directory to the list:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - metallb/
  - sealed-secrets/
```

These files have already been created in this repository. **Commit and push them** before running the Flux bootstrap in Phase 3:

```bash
git add infrastructure/
git commit -m "Add SealedSecrets controller to infrastructure"
git push
```

When Flux bootstraps in Phase 3, it will install the SealedSecrets controller alongside MetalLB as part of the `infra-controllers` layer. Both will be healthy before the `apps` layer starts deploying Artifactory.

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

> **What is a Personal Access Token?** GitHub uses these as an alternative to your password for API access and scripted operations. The `repo` scope means the token is allowed to read and write to your repositories. Flux needs it during bootstrap to: push the generated Flux config files to the repo, and register a deploy key on the repo. After bootstrap, Flux switches to using the SSH deploy key and the token is no longer needed (though you can keep it for re-bootstrapping).

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
6. Generates an SSH deploy key, adds it to the GitHub repo as a deploy key, and stores the private key in the cluster as a Secret called `flux-system` — this is how Flux authenticates to pull from GitHub going forward

> **What is `gotk`?** It stands for "GitOps Toolkit" — the underlying project that Flux v2 is built on. The files are named with the `gotk-` prefix to distinguish them from your own config files. You'll never need to edit them directly.

After bootstrap completes, **Flux is running and watching the repo**. It will immediately start reconciling everything under `clusters/lab/` — installing MetalLB, configuring it, and deploying Artifactory. The whole stack takes 5–10 minutes to fully come up.

Watch it happen in real time:

```bash
flux get kustomizations -A --watch
```

> **What does the `-A` flag do?** `-A` is short for `--all-namespaces` — it shows resources across all namespaces, not just the default one. Adding `--watch` keeps the command running and refreshes the output as things change, like `watch kubectl get pods`.

---

## 7.1 Post-Bootstrap: Seal the Database Credentials

After Flux has bootstrapped and the `infra-controllers` layer is fully healthy, the SealedSecrets controller is running in the cluster. You can now encrypt the Artifactory database credentials and commit them to git.

Verify the controller is running before continuing:

```bash
kubectl get pods -n sealed-secrets
# NAME                                        READY   STATUS    RESTARTS
# sealed-secrets-controller-<hash>            1/1     Running   0
```

### Install the `kubeseal` CLI

`kubeseal` is the command-line tool that encrypts secrets. Install it on your laptop — wherever you run `kubectl` and `flux` commands from.

```bash
# macOS
brew install kubeseal

# Linux (download the binary directly)
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest \
  | grep '"tag_name"' | cut -d '"' -f 4 | cut -c 2-)
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

> **Why does the `kubeseal` version need to match the controller?** `kubeseal` and the controller must agree on the encryption format. Minor version differences are usually fine, but using a very old `kubeseal` with a new controller (or vice versa) can produce SealedSecrets the controller cannot decrypt. The commands above always download the latest release to match a freshly-installed controller.

### Fetch the controller's public certificate

`kubeseal` encrypts secrets using the controller's public certificate. Fetch it and save it locally — you will need this file every time you want to seal a new secret.

```bash
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  > pub-sealed-secrets.pem
```

> **What is a `.pem` file?** PEM (Privacy-Enhanced Mail — yes, an old name) is a text-based format for cryptographic objects like certificates and keys. The file contains Base64-encoded data between `-----BEGIN CERTIFICATE-----` and `-----END CERTIFICATE-----` markers. It is just the controller's public key saved in a standard format that `kubeseal` understands.
>
> **Why save it to a file rather than fetching it on demand?** If the controller is restarted or the cluster is rebuilt, the certificate changes. Saving it to a file means you always encrypt with the certificate that *this specific cluster instance* can decrypt. Keep the `.pem` file alongside your local checkout but **do not commit it to git** — it is not a secret (it is a public key), but keeping it out of git avoids confusion. If you lose it, you can always re-run `--fetch-cert` from a running controller.

### Create and commit the SealedSecret

This is a two-step process: first generate the Secret YAML (without applying it to the cluster), then pipe it through `kubeseal` to produce the encrypted SealedSecret YAML.

**Step 1 — Generate and encrypt in one command.**

The `--dry-run=client -o yaml` flags tell `kubectl` to print what it *would* create as YAML without actually sending it to the cluster. That YAML is piped directly into `kubeseal`, which encrypts it and writes the result to a file:

```bash
kubectl create secret generic artifactory-db-credentials \
  --namespace=artifactory \
  --from-literal=password="<choose-a-strong-password>" \
  --from-literal=postgresPassword="<choose-a-strong-postgres-password>" \
  --dry-run=client -o yaml \
| kubeseal \
  --cert=pub-sealed-secrets.pem \
  --format=yaml \
  > apps/artifactory/sealed-artifactory-db-credentials.yaml
```

> **Why use `--dry-run=client` rather than applying the Secret first?** Because the whole point is that the plain-text password never touches the cluster — and never needs to. `--dry-run=client` generates the correctly-formatted Secret YAML locally, and `kubeseal` encrypts it before it ever reaches any API call. The plain-text password only exists briefly in your terminal session and is never written to disk in readable form.

The output file will look something like this. The actual encrypted values are unique to your cluster and controller key — they will be long strings of random-looking characters:

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  creationTimestamp: null
  name: artifactory-db-credentials
  namespace: artifactory
spec:
  encryptedData:
    password: AgBzK7LmXp...several hundred characters...
    postgresPassword: AgA2k9mPRq...several hundred characters...
  template:
    metadata:
      creationTimestamp: null
      name: artifactory-db-credentials
      namespace: artifactory
```

> **Why is the namespace inside the SealedSecret?** By default, a SealedSecret is bound to both its name and its namespace. The SealedSecrets controller will refuse to decrypt it if you try to apply it to a different namespace. This is a deliberate security feature — it prevents someone from copying a sealed credential from one application's namespace and using it in another. The `--namespace=artifactory` in the `kubectl create secret` command above ensures the resulting SealedSecret is locked to the `artifactory` namespace.

**Step 2 — Add it to the kustomization list.**

Edit `apps/artifactory/kustomization.yaml` to include the new file:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - postgresql-pv.yaml
  - artifactory-pv.yaml
  - sealed-artifactory-db-credentials.yaml
  # NOTE: Put this last when all dependencies are set
  - helmrelease.yaml
```

**Step 3 — Commit and push:**

```bash
git add apps/artifactory/sealed-artifactory-db-credentials.yaml
git add apps/artifactory/kustomization.yaml
git commit -m "Add sealed Artifactory database credentials"
git push
```

Flux detects the new commit within 1 minute. Watch what happens:

```bash
# Watch the SealedSecrets controller decrypt it and create the real Secret
kubectl get secret -n artifactory --watch

# Once artifactory-db-credentials appears, watch the HelmRelease progress
flux get helmrelease -n artifactory --watch
```

The sequence of events:
1. `source-controller` detects the new commit and downloads it
2. The `apps` Kustomization reconciles: applies the SealedSecret and the HelmRelease objects
3. The SealedSecrets controller sees the new SealedSecret, decrypts it, and creates a regular `Secret` named `artifactory-db-credentials` in the `artifactory` namespace
4. The helm-controller reconciles the HelmRelease; `valuesFrom` reads from `artifactory-db-credentials` and passes the credentials to Helm
5. PostgreSQL initialises with your chosen passwords; Artifactory connects successfully

> **What if the HelmRelease briefly shows a failure?** The SealedSecrets controller and the helm-controller may race — Helm might try to read `artifactory-db-credentials` a few seconds before the controller has finished creating it. This is normal. Flux retries failed HelmReleases automatically. Once the Secret exists (usually within seconds), the next retry will succeed and the HelmRelease will show `READY=True`. You do not need to intervene.

### What happens when you rebuild the cluster?

The SealedSecrets controller generates a **unique private key** when it first starts. If you tear down and rebuild the cluster, the new controller instance generates a **different** private key — and cannot decrypt the SealedSecret you committed to git (it was encrypted with the old key).

There are two ways to handle this:

**Option A — Restore the backed-up private key (recommended):**

You backed up the controller's private key in Section 4 (Tear Down) before resetting. After rebuilding and re-bootstrapping Flux (Phases 1–3), restore it *before* the controller has a chance to create its own key:

```bash
# Scale the controller to zero so it stops running temporarily
kubectl scale deployment sealed-secrets-controller -n sealed-secrets --replicas=0

# Restore the backed-up key
kubectl apply -f ~/sealed-secrets-master-key-backup.yaml

# Scale back up — the controller loads the restored key on startup
kubectl scale deployment sealed-secrets-controller -n sealed-secrets --replicas=1
```

The controller now holds the same private key as before and can decrypt your existing SealedSecrets from git.

> **Why scale to zero first?** If the controller is already running when you restore the key, it may already have generated a new key of its own. Scaling down first ensures the controller isn't running during the restore, so when it starts back up it only sees your restored key and doesn't get confused by having two keys at once.

**Option B — Re-seal all secrets after rebuild:**

If you didn't back up the key (or prefer a clean slate), after the new controller is running:

```bash
# Fetch the new controller's public certificate
kubeseal --fetch-cert \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=sealed-secrets \
  > pub-sealed-secrets.pem

# Re-seal the credentials with the new key — you will need your original passwords
kubectl create secret generic artifactory-db-credentials \
  --namespace=artifactory \
  --from-literal=password="<your-password>" \
  --from-literal=postgresPassword="<your-postgres-password>" \
  --dry-run=client -o yaml \
| kubeseal \
  --cert=pub-sealed-secrets.pem \
  --format=yaml \
  > apps/artifactory/sealed-artifactory-db-credentials.yaml

git add apps/artifactory/sealed-artifactory-db-credentials.yaml
git commit -m "Re-seal credentials with new controller key after cluster rebuild"
git push
```

> **Why is Option A better?** To re-seal, you need to know the original passwords. If you only ever stored them in the SealedSecret and nowhere else, you are stuck — you would need to wipe the PostgreSQL data directory and start completely fresh (see [PostgreSQL password mismatch](#postgresql-password-mismatch)). The key backup avoids this situation entirely.

---

## 8. Phase 4: Artifactory Deployment

After the Flux bootstrap in Phase 3, Flux begins reconciling the repository immediately. Within a few minutes it works through the dependency chain — registering the Helm repositories, installing MetalLB, configuring the IP pool — and then deploys Artifactory. You don't run any commands for this; it happens automatically.

This section explains what Artifactory is, what gets deployed, and how to tell when it's up.

---

### What is Artifactory?

Artifactory is a **universal artifact repository manager** — a centralised store for every kind of build output your software pipeline produces. Think of it as a private, self-hosted version of the public package registries you already use:

| What you might store | Public equivalent |
|---|---|
| Docker container images | Docker Hub |
| Helm charts | Artifact Hub / chart repos |
| Maven JARs / WARs | Maven Central |
| npm packages | npmjs.com |
| Python packages | PyPI |
| Raw binaries and files | — |

In this lab, the primary use case is as a **private Docker registry** — a place to push images that your cluster can pull from, without relying on a public registry. The future image tag automation (Section 15) depends on images being pushed here.

---

### What Flux deploys

The `artifactory-oss` Helm chart creates three StatefulSets (one per persistent component) plus supporting resources:

| Pod | What it is | Why it exists |
|---|---|---|
| `artifactory-oss-0` | The main Artifactory application | The Java server that handles all repository operations — push, pull, search, permissions |
| `artifactory-oss-artifactory-nginx-*` | An nginx reverse proxy | Sits in front of Artifactory as the external-facing entry point. This is the pod that gets the LoadBalancer IP (`192.168.56.200`) from MetalLB. All browser and Docker client traffic hits nginx first. |
| `artifactory-oss-postgresql-0` | A PostgreSQL database | Stores Artifactory's metadata: repository configuration, user accounts, permissions, audit logs, and build information. The actual binary artifacts (images, packages) are stored on disk, not in the database. |

> **Why nginx in front of Artifactory?** Artifactory itself listens on port 8082. nginx handles the "polished" external interface: it serves on standard ports (80/443), adds headers, handles TLS termination if configured, and provides Docker registry routing (Docker's registry protocol has specific URL patterns that nginx maps to Artifactory's internal paths). You interact with nginx — nginx proxies to Artifactory.

> **Why is the Artifactory pod shown as `9/9`?** Artifactory OSS runs multiple **sidecar containers** inside a single pod. Each sidecar handles a specific internal service (e.g., `access` handles authentication, `metadata` handles package metadata APIs, `topology` tracks cluster node state, `router` handles inter-service routing). They all share the pod's network and storage. The `9/9` means all 9 containers in the pod are running and passing their readiness checks.

---

### Watch it come up

After the Flux bootstrap completes, open two terminals and watch the deployment progress:

**Terminal 1 — watch Flux Kustomizations work through the dependency chain:**
```bash
flux get kustomizations -A --watch
```

You'll see them flip to `READY=True` in order: `infra-repositories` first, then `infra-controllers` (this one takes a few minutes — it's waiting for MetalLB pods to become healthy), then `infra-configs`, then `apps`.

**Terminal 2 — watch the Artifactory pods come up:**
```bash
kubectl get pods -n artifactory --watch
```

You'll see pods appear one by one. They'll initially show states like `Init:0/1`, `PodInitializing`, or `0/9` — this is normal. Artifactory initialises in stages:

1. PostgreSQL starts first and initialises its database
2. The main Artifactory pod starts, connects to PostgreSQL, and runs database migrations
3. The sidecar containers start one by one as Artifactory's internal services come online
4. nginx starts last, once Artifactory is ready to receive proxied requests

**The whole process takes 5–10 minutes on a cold start.** Artifactory is a large Java application — it has a lot to initialise.

---

### Verify Artifactory is fully up

```bash
kubectl get pods -n artifactory
```

Expected output:
```
NAME                                           READY   STATUS    RESTARTS
artifactory-oss-0                              9/9     Running   0
artifactory-oss-artifactory-nginx-<hash>       1/1     Running   0
artifactory-oss-postgresql-0                   1/1     Running   0
```
 
```bash
kubectl get svc -n artifactory
```

Look for `artifactory-oss-artifactory-nginx` showing `EXTERNAL-IP: 192.168.56.200`. If it still shows `<pending>`, MetalLB hasn't assigned an IP yet — check `flux get kustomizations -A` to see if `infra-configs` is ready.

---

### First login

Open a browser on any machine that can reach the `192.168.56.x` subnet:

```
http://192.168.56.200
```

Default credentials:
```
Username: admin
Password: password
```

> Artifactory will immediately prompt you to change the admin password and run a setup wizard. Change the password. You can skip or dismiss the wizard for lab purposes — the repositories and settings you need can be configured later through the UI or API.

---

## 9. How GitOps Works Here

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
| `source-controller` | Polls git repos and Helm chart repos for changes. When it detects a new commit or chart version, it downloads and caches it locally so other controllers can use it. |
| `kustomize-controller` | Reads `Kustomization` objects and applies the referenced YAML files to the cluster — essentially running `kubectl apply` on your behalf, but with health checking and dependency ordering. |
| `helm-controller` | Reads `HelmRelease` objects and runs Helm install, upgrade, or rollback operations to keep the installed charts matching the spec. |

> **What is kustomize?** Kustomize is a tool for customising Kubernetes YAML without modifying the original files. You write a `kustomization.yaml` file that lists which YAML files to include, and optionally applies patches or overrides on top. In this repo it's used in its simplest form: just listing which files to include (no patching). Flux's `kustomize-controller` uses it internally when applying resources.

### Two things called "Kustomization" — and why it's confusing

There are **two completely different things** called `Kustomization` in this setup:

| Kind | API group | What it is |
|---|---|---|
| `Kustomization` | `kustomize.config.k8s.io/v1beta1` | A plain kustomize manifest — just a list of files to include. This is the original kustomize tool's object. |
| `Kustomization` | `kustomize.toolkit.fluxcd.io/v1` | A **Flux CRD** — tells the kustomize-controller to fetch a path from git and apply it, with interval scheduling, health checking, and `dependsOn` ordering. This is Flux's own custom resource type. |

> **What is a CRD (Custom Resource Definition)?** Kubernetes's API is extensible. By default, it knows about built-in resource types like Pod, Service, Deployment, etc. A CRD is a way for software to add its own new resource types to the Kubernetes API. When MetalLB installs, it registers CRDs for `IPAddressPool` and `L2Advertisement` — types that didn't exist before MetalLB was installed. Once a CRD is registered, you can create, read, update, and delete objects of that type using `kubectl` just like any built-in resource. When Flux is installed, it registers its own CRDs: `GitRepository`, `Kustomization` (the Flux kind), `HelmRepository`, `HelmRelease`, etc.

In this repo, `clusters/lab/kustomization.yaml` is the first kind (a plain list). The files it lists — `infrastructure.yaml` and `apps.yaml` — contain the second kind (Flux objects that independently reconcile parts of the cluster). Every time you see a `Kustomization`, check the `apiVersion` to know which one you're dealing with.

---

## 10. Repository Structure

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
│   │   ├── sealed-secrets.yaml
│   │   └── kustomization.yaml
│   │
│   ├── controllers/                  # Helm charts that install controllers + their CRDs
│   │   ├── kustomization.yaml
│   │   ├── metallb/
│   │   │   ├── namespace.yaml
│   │   │   ├── helmrelease.yaml
│   │   │   └── kustomization.yaml
│   │   └── sealed-secrets/           # Bitnami SealedSecrets controller
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
        ├── sealed-artifactory-db-credentials.yaml  # created in Section 7.1 with kubeseal
        ├── helmrelease.yaml
        └── kustomization.yaml
```

### Why this layout?

**`clusters/`** contains one directory per cluster. Everything in `clusters/lab/` is specific to this cluster. The `infrastructure/` and `apps/` directories are cluster-agnostic — a second cluster (`clusters/staging/`) could reference the same definitions with different overlays.

**`infrastructure/` is split into three layers** because of a hard ordering constraint:

```
repositories/ ← controllers/ ← configs/
```

- `repositories/` — tells Flux where to find Helm charts (like adding a package repository). Everything else depends on these existing first.
- `controllers/` — installs controllers (MetalLB) via Helm. As a side effect, this installs MetalLB's **Custom Resource Definitions** (CRDs) into the cluster — making new resource types like `IPAddressPool` available.
- `configs/` — creates objects of the CRD types that were just installed by `controllers/`. This layer cannot run before `controllers/` finishes, because the CRD types won't exist yet and Kubernetes will reject the objects with `no matches for kind IPAddressPool`.

**`apps/`** waits for the entire infrastructure chain. Artifactory needs MetalLB running (to handle its `LoadBalancer` Service request) and the IP pool configured (so MetalLB knows which IPs it can hand out).

> **What is a LoadBalancer Service?** A Kubernetes Service is an abstraction that gives a stable IP address to a set of pods. There are several Service types. `ClusterIP` (the default) gives a stable internal IP only accessible inside the cluster. `NodePort` exposes the service on a specific port of every node's IP. `LoadBalancer` requests an external IP from a load balancer — on cloud providers (AWS, GCP, Azure), this automatically provisions a cloud load balancer. On bare metal, there's no cloud provider, so nothing would assign the external IP... unless you install MetalLB, which fills exactly that role.

---

## 11. File-by-File Reference

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

**Key fields explained:**

- **`interval`** — how often Flux re-applies this Kustomization, even if nothing has changed in git. This is the "drift detection" mechanism: if someone manually deletes a resource from the cluster, Flux will recreate it on the next interval cycle.
- **`retryInterval`** — if a reconcile attempt fails, how long to wait before trying again.
- **`timeout`** — if the reconcile hasn't completed within this time, treat it as failed.
- **`sourceRef`** — which `GitRepository` object to fetch YAML from. All three point at `flux-system` — the GitRepository that tracks this repo, created by bootstrap.
- **`path`** — the directory within the git repo to apply.
- **`prune: true`** — if you delete a YAML file from the repo (and the corresponding resource disappears from the Kustomization's path), Flux will delete the resource from the cluster too. Without this, removing a file from git would leave the old resource orphaned in the cluster.

**Why `dependsOn` is critical here:** `IPAddressPool` and `L2Advertisement` (in `configs/`) are custom resource types that are installed by the MetalLB Helm chart (in `controllers/`). If `configs/` were applied before MetalLB was installed, Kubernetes would reject the objects with `no matches for kind IPAddressPool`. `dependsOn` prevents this race condition by making `infra-configs` wait until `infra-controllers` reports healthy.

**`wait: true` on `infra-controllers`** tells the kustomize-controller to wait until all resources — including the MetalLB HelmRelease — are fully healthy before marking this Kustomization as ready. Without `wait: true`, `infra-configs` could start immediately after the HelmRelease *object* is created in the cluster, before MetalLB has actually finished deploying and its CRDs are registered. The CRDs wouldn't exist yet and the config apply would fail.

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

Apps depend on both `infra-controllers` and `infra-configs` because a `LoadBalancer` Service needs MetalLB to be running *and* an `IPAddressPool` to exist. MetalLB won't assign an IP from a pool that hasn't been defined yet — the Service will sit in `<pending>` forever if either is missing.

---

### `infrastructure/repositories/`

Before the helm-controller can install a chart, the source-controller needs to know where to find it. `HelmRepository` objects are the GitOps equivalent of running `helm repo add` — they tell Flux "here is a Helm chart repository URL, go check it for charts."

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

> **Why declare a Namespace in git if Helm can create it?** If Flux has `prune: true` and Helm owns the namespace (because Helm created it), then deleting the HelmRelease from git would also delete the namespace and everything inside it — including running pods. By declaring the namespace separately in git, Flux owns it directly, and it exists independently. You can delete and recreate the HelmRelease without losing the namespace.

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

**`crds: CreateReplace`** is essential. Without it, Flux installs the CRDs on first install but never updates them when you bump the chart version. As MetalLB releases new versions, its CRD schemas can evolve — if the CRDs are stale, new MetalLB features won't work, and in the worst case the old CRD schema will conflict with what the new MetalLB pods expect.

---

### `infrastructure/controllers/sealed-secrets/`

The SealedSecrets controller is also installed via Helm. Unlike MetalLB, it does not install any CRDs that other layers depend on — it simply runs a controller that watches for `SealedSecret` objects and converts them into regular Kubernetes `Secret` objects.

**`controllers/sealed-secrets/helmrelease.yaml`**
```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: sealed-secrets
  namespace: sealed-secrets
spec:
  interval: 15m
  chart:
    spec:
      chart: sealed-secrets
      version: "2.16.1"
      sourceRef:
        kind: HelmRepository
        name: sealed-secrets
        namespace: flux-system
  install:
    createNamespace: true
  values:
    fullnameOverride: sealed-secrets-controller
```

There is no `namespace.yaml` for sealed-secrets — `createNamespace: true` lets the Helm chart create the `sealed-secrets` namespace as part of installation. There are also no CRDs managed here (`crds: CreateReplace` is omitted) because the SealedSecrets chart registers its `SealedSecret` CRD as part of the chart itself and it never needs to be managed independently.

The `fullnameOverride: sealed-secrets-controller` value ensures the controller's Deployment and Service are named `sealed-secrets-controller` inside the `sealed-secrets` namespace. This matches what the `kubeseal` CLI expects to find, so you can run `kubeseal --fetch-cert` without specifying extra `--controller-name` flags beyond `--controller-namespace sealed-secrets`.

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

**`IPAddressPool`** tells MetalLB "you are allowed to assign addresses from this range to LoadBalancer Services." When a Service of type `LoadBalancer` is created, MetalLB picks an available IP from this pool and assigns it as the `EXTERNAL-IP`.

**`L2Advertisement`** tells MetalLB to use **Layer 2 / ARP mode** to advertise those IPs.

> **What is ARP?** ARP (Address Resolution Protocol) is how devices on a local network discover each other's hardware (MAC) addresses. When your laptop wants to send a packet to `192.168.56.200`, it first broadcasts a message to the whole subnet: "Who has IP 192.168.56.200? Tell me your MAC address." Normally, the device that owns that IP responds with its MAC address, and your laptop then sends the packet directly to that MAC address at the Ethernet level.
>
> **How does MetalLB use ARP?** When MetalLB assigns `192.168.56.200` to a LoadBalancer Service, it makes one of its **speaker pods** respond to ARP requests for that IP — even though `192.168.56.200` isn't a real IP configured on any physical network interface. The speaker pod says "I own that IP — send traffic here." Traffic then arrives at that node, where MetalLB forwards it to the appropriate Service backend pods. This works on any standard LAN without needing any router configuration.
>
> **What is Layer 2?** The network stack has multiple layers. Layer 1 is the physical medium (cables, WiFi signals). Layer 2 is the data link layer — this is where MAC addresses live and where Ethernet frames are sent between devices on the same local network. ARP operates at Layer 2. The alternative to Layer 2 mode is BGP mode, which operates at Layer 3 (the IP routing layer) and requires a BGP-capable router — overkill for a lab.

The IP range must:
- Be in the same subnet as the nodes (`192.168.56.0/24`)
- Not overlap with your router/DHCP server's range (to avoid IP conflicts)

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

**`persistentVolumeReclaimPolicy: Retain`** — when the PVC that's bound to this PV is deleted (e.g., when the Helm chart is uninstalled), the PV and its data are *not* deleted. They stay around, available to be reclaimed and rebound. The alternative, `Delete`, would delete the underlying storage — catastrophic for a database.

**`storageClassName: ""`** is critical. If this field is absent or set to a real StorageClass name, Kubernetes will try dynamic provisioning instead of binding to this manually-defined PV.

> **What is dynamic vs static provisioning?** In cloud environments, Kubernetes can automatically create storage volumes on demand (dynamic provisioning): when a PVC is created, a StorageClass instructs a storage provider to create and attach a real disk. In this lab, there's no storage provider — we've manually created the PV (static provisioning). The empty `storageClassName: ""` tells Kubernetes "don't use dynamic provisioning; bind to a manually-created PV that also has `storageClassName: ""`."

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

**`apps/artifactory/sealed-artifactory-db-credentials.yaml`** — the encrypted database credentials

This file is **generated by `kubeseal`** in Section 7.1 and then committed to git. It does not exist in the repository until you run through that section. It looks roughly like this (the actual encrypted values will be unique to your cluster):

```yaml
apiVersion: bitnami.com/v1alpha1
kind: SealedSecret
metadata:
  name: artifactory-db-credentials
  namespace: artifactory
spec:
  encryptedData:
    password: AgBzK7LmXp...long encrypted string unique to your cluster...
    postgresPassword: AgA2k9mPRq...long encrypted string unique to your cluster...
  template:
    metadata:
      name: artifactory-db-credentials
      namespace: artifactory
```

> **What happens when Flux applies this?** The `SealedSecret` is a custom resource type registered by the SealedSecrets controller. When the controller sees a new `SealedSecret` object appear in the cluster, it reads the `encryptedData` fields, decrypts them using its private key, and creates a standard Kubernetes `Secret` with the decrypted values — in this case, a Secret named `artifactory-db-credentials` in the `artifactory` namespace. The Artifactory HelmRelease then reads that Secret via `valuesFrom`, passing the credentials to Helm. The SealedSecret and the real Secret coexist in the cluster; the SealedSecret is the persistent GitOps-managed representation, and the real Secret is what applications actually use.

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

**`interval: 5m`** means any manual `helm upgrade` on the cluster will be reverted within 5 minutes. This enforces the GitOps contract: all changes go through git, not the CLI. If you run `helm upgrade` directly, Flux will overwrite your change on the next reconcile cycle.

**`valuesFrom`** pulls values from a Kubernetes Secret and injects them into the Helm chart at the specified `targetPath`. This is how Flux passes sensitive config to a chart without putting secrets in git.

> **How does `valuesFrom` work?** Helm charts are configured via "values" — a hierarchical set of key-value pairs. Normally you'd write values directly in the HelmRelease YAML (e.g., `values: postgresql: auth: password: mypassword`). But that would put the password in git. Instead, `valuesFrom` says "fetch the value from this Secret, from this key within the Secret, and inject it into the chart at this path in the values hierarchy." The result is identical to writing the value inline, but the actual secret never appears in git.

The Secret `artifactory-db-credentials` must already exist in the `artifactory` namespace before the HelmRelease reconciles — create it manually as described in [Phase 2.2](#62-create-the-database-credentials-secret).

The two `targetPath` values map to the Bitnami PostgreSQL subchart's configuration:
- `postgresql.auth.password` — the password for the `artifactory` database user (used by the Artifactory application)
- `postgresql.auth.postgresPassword` — the password for the `postgres` superuser (used for database administration)

By pinning these here, every Flux reconcile passes the same credentials to Helm rather than letting the chart generate new random ones.

---

## 12. How the Files Relate to Each Other

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
    → HelmRelease "sealed-secrets"
         → helm-controller installs sealed-secrets chart
              → SealedSecrets controller running in "sealed-secrets" namespace
              → Can now decrypt SealedSecret objects into real Secrets

infra-configs  [waits for: infra-controllers + wait:true]
  path: ./infrastructure/configs
    → IPAddressPool "default"       (192.168.56.200–210)
    → L2Advertisement "default"     (announce via ARP)

apps  [waits for: infra-controllers + infra-configs]
  path: ./apps
    → Namespace "artifactory"
    → PersistentVolume "artifactory-pv-0"
    → PersistentVolume "postgres-pv-0"
    → SealedSecret "artifactory-db-credentials"
         → sealed-secrets-controller decrypts it
              → Secret "artifactory-db-credentials" created in "artifactory" namespace
    → HelmRelease "artifactory-oss"
         → helm-controller reads Secret via valuesFrom
         → installs artifactory-oss chart with fixed credentials
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

## 13. Verification Commands

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

> **What does `9/9` mean?** The format is `ready/total`. Artifactory is a complex application — the Helm chart deploys multiple processes inside the same pod as **sidecars** (containers that run alongside the main process, typically handling supporting functions like access control, metadata indexing, topology, etc.). `9/9` means all 9 containers in that pod are running and passing their readiness probes.

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

## 14. Troubleshooting

### Flux hasn't picked up a push

```bash
flux get source git flux-system -n flux-system
```

Check `REVISION` matches your latest git commit SHA. Flux polls every 1 minute. Force an immediate sync:

```bash
flux reconcile source git flux-system -n flux-system
```

> **What is a commit SHA?** Every git commit is identified by a SHA (Secure Hash Algorithm) — a 40-character hexadecimal fingerprint of the commit's contents. It looks like `da1bc2248f3a...`. When Flux shows a REVISION, it shows this SHA — you can compare it to `git log --oneline -1` to see if Flux has seen your latest push.

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

> **What does `--with-source` do?** It tells Flux to re-fetch the chart from the Helm repository before reconciling, rather than using its cached copy. Useful if you suspect the cached chart is stale.

If the `flux` CLI isn't available, use `kubectl` annotations:

```bash
kubectl annotate helmrelease <name> -n <namespace> \
  reconcile.fluxcd.io/requestedAt="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --overwrite
```

> **What is an annotation?** Kubernetes resources can have arbitrary key-value metadata attached called annotations. Some tools use specific annotation keys as signals — adding or updating the `reconcile.fluxcd.io/requestedAt` annotation is the equivalent of saying "please reconcile this right now" without needing the Flux CLI.

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
- IP range overlaps with your DHCP server (your router would have already assigned that IP to another device — two devices claiming the same IP causes an IP conflict and neither works reliably)
- `L2Advertisement.spec.ipAddressPools` name doesn't match `IPAddressPool.metadata.name`

### PostgreSQL password mismatch

**Symptoms:** Multiple Artifactory sidecars (`topology`, `metadata`, `access`) in `CrashLoopBackOff`. Logs show `FATAL: password authentication failed for user "artifactory"`.

> **What is CrashLoopBackOff?** When a container crashes immediately after starting, Kubernetes tries to restart it. If it keeps crashing, Kubernetes enters a "back-off" — it waits increasingly longer between restart attempts (1s, 2s, 4s, 8s... up to 5 minutes). During this state, the pod shows `CrashLoopBackOff`. It means "this container is repeatedly failing to start."

**Cause:** The Bitnami PostgreSQL subchart generates a random password on every Helm install or upgrade. If the `artifactory-db-credentials` Secret is missing, Flux lets the chart manage its own secret (`artifactory-oss-postgresql`). On the next reconcile, the chart regenerates a new random value in that secret — but the PostgreSQL data directory was initialised with the original password. The two are now out of sync.

> **Why can't PostgreSQL just use the new password?** PostgreSQL stores its user credentials *inside* the database files on disk. When the database was first initialised, it created a user `artifactory` with password X. Changing the Secret in Kubernetes doesn't change the password stored in the database files — that would require running a SQL command (`ALTER USER artifactory PASSWORD '...'`). Since the application can't connect (wrong password), it can't run that SQL command either. The only clean fix is to wipe the database and reinitialise it from scratch.

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

> **Why is the Secret value base64-encoded?** Kubernetes Secrets store values as base64. Base64 is an encoding scheme (not encryption) that converts binary data into a safe ASCII string. It's used here because Secret values can be arbitrary bytes — not necessarily valid UTF-8 text. The `python3` command decodes each base64 value back to readable text.

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

   > **What is a StatefulSet?** A StatefulSet is a Kubernetes workload type designed for stateful applications (databases, queues, etc.) that need stable network identities and persistent storage. Unlike a Deployment (where pods are interchangeable), StatefulSet pods have fixed names (`artifactory-oss-0`, `artifactory-oss-1`, etc.) and each gets its own PersistentVolumeClaim. Scaling to `--replicas=0` stops all pods in the StatefulSet without deleting it or its storage.

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

### SealedSecret not being decrypted

**Symptoms:** The `artifactory-db-credentials` Secret does not appear after Flux applies the SealedSecret. Artifactory pods fail to start because the Secret doesn't exist.

Check the controller logs — it will usually print exactly why it refused to decrypt:

```bash
kubectl logs -n sealed-secrets -l app.kubernetes.io/instance=sealed-secrets --tail=50
```

Common causes:

- **Controller generated a new key after cluster rebuild** — the SealedSecret was encrypted with the old private key and the new controller cannot decrypt it. Re-seal the credentials using the new key (see [Section 7.1 — What happens when you rebuild the cluster?](#71-post-bootstrap-seal-the-database-credentials)).
- **Namespace mismatch** — a SealedSecret is namespace-scoped; it can only be decrypted in the namespace specified in its `metadata.namespace`. Check that the SealedSecret has `namespace: artifactory`, not `namespace: default` or something else.
- **`kubeseal` version mismatch with controller** — re-install `kubeseal` to match the controller version (check `kubectl get deployment -n sealed-secrets -o jsonpath='{.items[0].spec.template.spec.containers[0].image}'` for the controller image tag).

### SealedSecrets controller HelmRelease stuck

If `flux get helmrelease -n sealed-secrets` shows an error or the controller pod never appears:

```bash
kubectl describe helmrelease -n sealed-secrets sealed-secrets
kubectl get events -n sealed-secrets
```

The most common cause is the `sealed-secrets` HelmRepository not yet being ready — check `flux get sources helm -n flux-system`. If `infra-repositories` hasn't reconciled yet, wait for it or force it:

```bash
flux reconcile kustomization infra-repositories -n flux-system
```

### Artifactory startup probe failures

Artifactory takes 2–5 minutes to initialise from a cold start. Startup probe failures in the first few minutes are normal.

> **What is a startup probe?** Kubernetes has three types of health checks for containers. A **startup probe** checks whether the application has finished starting up — Kubernetes won't send traffic to the container until the startup probe passes, and it won't start the other health checks (liveness and readiness probes) until then either. This is important for slow-starting apps like Artifactory: without a startup probe, the liveness probe would kick in too early, decide the app is dead, and restart it in a loop — preventing it from ever finishing startup.

Only investigate if failures persist beyond 10 minutes:

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

## 15. Future: Image Tag Automation

The goal: push a new image to Artifactory → Flux detects the new tag → updates the image tag in a HelmRelease → auto-deploys.

### What's missing

The current `gotk-components.yaml` deploys four controllers: `source-controller`, `kustomize-controller`, `helm-controller`, and `notification-controller`. Image automation needs two more:

| Controller | Job |
|---|---|
| `image-reflector-controller` | Scans a container registry and fetches the list of available image tags |
| `image-automation-controller` | Commits updated image tags back to git, triggering a new deployment |

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

**`image-repository.yaml`** — tells Flux which container registry and image to scan for new tags:
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

**`image-policy.yaml`** — defines which tag to select from all available tags (e.g., latest semver, latest matching a pattern):
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

> **What is semver?** Semver (Semantic Versioning) is a versioning convention: `MAJOR.MINOR.PATCH` (e.g., `1.4.2`). The policy `>=1.0.0` means "select the highest available tag that is version 1.0.0 or greater." Flux will automatically select `1.4.2` over `1.3.0` and commit the update to git.

**`image-update-automation.yaml`** — commits the selected tag back to git, triggering Flux's normal reconcile flow:
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

The `image-automation-controller` reads this marker comment, replaces the tag value with whatever `ImagePolicy` selected, and commits the change to git. The `GitRepository` detects the new commit within 1 minute, the `apps` Kustomization reconciles, the HelmRelease upgrades — and the loop is complete. A full push-to-deploy pipeline with no manual intervention.
