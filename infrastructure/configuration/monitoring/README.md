# Management cluster monitoring

Stage 1 basic implementation forwards metrics from `admin@management` to the
existing estate VictoriaMetrics and Grafana, without a second database or operator.

`monitoring` is a management-only foundation Application (wave 95) in the existing
Argo CD catalog. It runs one vmagent, one kube-state-metrics, and a node-exporter
DaemonSet (three pods for the current Talos nodes). Versions match the estate:
vmagent v1.149.0, kube-state-metrics v2.20.0, node-exporter v1.12.1.

Signals: node CPU/memory/filesystems/network, Kubernetes object state, and a bounded
set of cAdvisor container CPU/memory/network/filesystem series. The collector uses
projected ServiceAccount credentials and verified kubelet TLS; its RBAC grants
`nodes/metrics`, not `nodes/proxy` or Secrets. Exporters listen on the pod network
and namespace ingress admits only vmagent to ports 8080/9100. Host PID and read-only
host mounts are required only by node-exporter; the namespace allows that host
access and has Istio injection disabled. No BGP or LAN firewall changes are needed.

vmagent sends HTTPS remote write to `https://metrics.adminio.biz/api/v1/write`.
TLS uses public roots. This reuses the receiver's existing private DNS/LAN allowlist;
there is no bearer credential on that receiver. This preserves the existing LAN
trust boundary. Every series carries `cluster="management",site="home"` and jobs
have the `management-` prefix. The estate owner controls retention and alerting;
this chart adds no storage retention setting and collects no logs.

## Delivery and acceptance

1. Review/merge the platform change. Argo reconciles the management project and
   Application from main; do not bypass it with workstation Helm installation.
2. Deploy the companion home-deployments change on the monitoring guest using
   `make apply PB=monitoring.yml TAGS=config,dashboards LIMIT=monitoring`.
   This installs the Management Kubernetes dashboard and the collector-absence
   and node-readiness alerts. Existing TargetDown covers exporter scrape failures.
   The dashboard is `/d/management-kubernetes` in Grafana.
3. Verify `kubectl --kubeconfig=/Users/amarkowskij/.kube/k8s-home -n monitoring get deploy,ds,pods`:
   vmagent and kube-state-metrics 1/1, node-exporter 3/3. Inspect vmagent logs for
   remote-write, RBAC or TLS errors. Port-forward its pod port 8429 to inspect
   `/targets` and `/metrics` if needed.
4. Query the estate backend for `count by(job)(up{cluster="management"})`: expect
   vmagent=1, kube-state-metrics=1, node=3, cadvisor=3, with all `up` values 1.
   Verify node_cpu_seconds_total, kube_node_status_condition and
   container_cpu_usage_seconds_total with the management cluster label, and open
   the dashboard. Check remote-write pending bytes drain and neither new alert fires.

## Loss model and rollback

The queue is a 1536Mi emptyDir capped at 1GiB by vmagent. It survives a container
restart, but pending unsent samples are lost when the pod is replaced; a long
backend outage can drop queued samples at the cap. Collection also pauses while
the single collector reschedules. These are explicit Stage 1 limits. History
already received remains in the estate backend.

Rollback: revert the catalog entry, disable `monitoring_enable_management` in the
companion Ansible change, and remove the dashboard if desired. Argo prune/delete
are disabled, so reverting Git alone does not stop collection: after review,
scale vmagent to zero or delete only the monitoring Application's chart resources.
Do not remove shared monitoring infrastructure or clear metric history.

## Ordered follow-up stages

1. Basic implementation: resources and companion dashboard/alerts prepared;
   platform `make check`, Ansible lint/syntax, 31 template renders, dashboard JSON
   parsing, and Git whitespace checks passed. Live deployment and acceptance
   remain pending approval.
2. Backup and restoration (separate prompt): validate config recreation and
   define/test buffering and recovery requirements against estate backend backups.
3. Security tightening (separate prompt): audit collector access and receiver
   trust, and add justified controls with runtime evidence.

Observed 2026-11-11: all three Talos v1.14.2 / Kubernetes v1.36.5 nodes Ready;
Argo child Applications Healthy, root management OutOfSync; no active metrics
collector. The old `vm-stack` namespace is Terminating due to four VictoriaMetrics
CR finalizers. This integration uses a separate namespace and does not alter them.
The estate backend query succeeded, showing OKE and estate jobs. Kubelet TLS on
10.0.10.101:10250 verified with the management cluster CA (unauthenticated HTTP
401). Python's older TLS runtime failed negotiation; curl verified successfully.

Notion documentation deferred by explicit user instruction for this task.
Last updated by: Codex — prepared management monitoring integration, 2026-11-11
