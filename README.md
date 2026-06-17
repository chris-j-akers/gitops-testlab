# Gitops Test Lab

This is a home lab continuoulsy under iteration to practice K8s deployments and general reliability.

The lab consists of a four-node K8s cluster built using Virtual Box and Rocky Linux. One control plane and three worker nodes.

Apps that need persistent storage will be pinned to nodes as there is no external storage available.

The LGTM stack (source in `./lgtm`) sits outside the cluster deliberately and will be run from the host.

Claude was used to generate objects such as initial Helm releases.

Any keys or secrets in the commit history are now out of date (This repo used to be private). Sealed Secrets is used to store current secrets.

## Deployed so Far

- K8s
    - Flannel
    - Metallb
- Grafana Alloy
- Bitnami Sealed Secrets
- Flux
- Artifactory (OSS version with PostGres)


## TODO

```
[X] VirtualBox machines set-up:
    [X] cakers-cp-1 (Control Plane)
    [X] cakers-worker-1 (Worker Node 1)
    [X] cakers-worker-2 (Worker Node 2)
    [X] cakers-worker-3 (Worker Node 3)
[X] K8s cluster build
    [X] Control Plane initialised
    [X] Flannel
    [X] Metallb deployed
    [X] Worker nodes initialised and joined Control Plane
    [X] Bitnami Sealed Secrets deployed
[X] Flux deployed and hooked up to ssh://git@github.com/chris-j-akers/gitops-testlab
[X] Grafana Alloy installed
[X] LGTM stack configured outside cluster
    [X] Loki configured to collect from K8s logs
    [X] Prom metrics collect and sending to Mimir
[X] Artifactory deployed
[X] Get one of my apps on Github to auto-deploy to Docker hub (mystory)
[X] Add Helm chart to deploy mystory app to cluster
    [X] Create Helm chart for mystory
    [ ] Upload mystory helm chart into artifcatory
    [ ] Register my artifactory repository with flux
    [ ] Adjust mystory app to use helm chart from Artifactory in cluster.
[ ] Python app to generate some stats written
    [ ] Release process to auto-deploy Python app to Artificatory
    [ ] Adjust flux to auto-deploy specific versions in chart
[ ] Alert manager set-up and forwarding alert (to email)
[ ] Replace Flannel with Cilium
[ ] Beyler configured in cluster (might clash with Cilium?)
[ ] Migrate all to Kapitan?
[ ] Looks like Artifactory OSS doesn't support a load of stuff I need. Install Harbour instead.
```
