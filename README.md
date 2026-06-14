# Gitops Test Lab


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
[X] Artifactory deployed
[ ] Python app to generate some stats written
    [ ] Release process to auto-deploy Python app to Artificatory
    [ ] Adjust flux to auto-deploy specific versions in chart
[ ] Alert manager set-up and forwarding alert (to email)
[ ] Bayler configured in cluster
```
