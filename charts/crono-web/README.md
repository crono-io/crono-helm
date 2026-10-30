# crono-web

![Version: 0.2.1](https://img.shields.io/badge/Version-0.2.1-informational?style=flat-square) ![Type: application](https://img.shields.io/badge/Type-application-informational?style=flat-square) ![AppVersion: 0.1.10](https://img.shields.io/badge/AppVersion-0.1.10-informational?style=flat-square)

crono-web: the crono single-page app served by unprivileged nginx. Route `/` to it and `/api` to crono-server on the same host.

## Install

```sh
helm install crono-web oci://ghcr.io/crono-io/charts/crono-web \
  --version 0.2.1 -n crono --create-namespace \
  --set ingress.enabled=true \
  --set ingress.host=crono.example.com \
  --set ingress.tls.secretName=crono-tls
```

The app calls `/api` on its own origin: install
[crono-server](../crono-server) with the same `ingress.host` (its Ingress
claims `/api`), or install both with `crono-stack`. For production, pin the
image by digest (`image.digest`, `requireImageDigest: true`).

## Requirements

Kubernetes: `>=1.30.0-0`

## Values

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| affinity | object | `{}` | Affinity. |
| autoscaling.enabled | bool | `false` | Render a HorizontalPodAutoscaler (replaces `replicaCount`). |
| autoscaling.maxReplicas | int | `6` | Maximum replicas. |
| autoscaling.minReplicas | int | `2` | Minimum replicas. |
| autoscaling.targetCPUUtilizationPercentage | int | `75` | Target average CPU utilization (percent of requests). |
| autoscaling.targetMemoryUtilizationPercentage | int | `80` | Target average memory utilization (percent of requests). |
| commonLabels | object | `{}` | Labels added to every rendered resource. |
| fullnameOverride | string | `""` | Override the full resource name (defaults to `<release>-<chart>`, or the release name when it already contains the chart name). |
| image.digest | string | `"sha256:227a949c48bda66bf6f76847e5ca04ff1f303c77d85fd10fcd4c1a8aef818c4e"` | Image index digest (`sha256:<64 hex>`, from the crono release notes). When set the image is pulled as `repository@digest`. |
| image.pullPolicy | string | `"IfNotPresent"` | Image pull policy. |
| image.repository | string | `"ghcr.io/crono-io/crono-web"` | Image repository. |
| image.tag | string | chart `appVersion` | Image tag. Ignored when `digest` is set. |
| imagePullSecrets | list | `[]` | Image pull secrets (names of existing kubernetes.io/dockerconfigjson Secrets). |
| ingress.annotations | object | `{}` | Ingress annotations (e.g. `cert-manager.io/cluster-issuer`). |
| ingress.className | string | `""` | IngressClass name; empty uses the cluster default. |
| ingress.enabled | bool | `false` | Render an Ingress routing `path` on `host` to crono-web. crono-server serves `/api` on the same host from its own Ingress. |
| ingress.host | string | `""` | REQUIRED when `enabled`. Public host name. |
| ingress.path | string | `"/"` | Path prefix. |
| ingress.pathType | string | `"Prefix"` | Ingress path type. |
| ingress.tls.enabled | bool | `true` | Terminate TLS for `host`. |
| ingress.tls.secretName | string | `""` | REQUIRED when `tls.enabled`. Existing (or cert-manager managed) TLS Secret for `host`. |
| nameOverride | string | `""` | Override the chart name used in resource names and labels. |
| networkPolicy.dns.ports | list | `[{"port":53,"protocol":"UDP"},{"port":53,"protocol":"TCP"}]` | DNS ports allowed to `dns.to`. |
| networkPolicy.dns.to | list | `[{"namespaceSelector":{"matchLabels":{"kubernetes.io/metadata.name":"kube-system"}},"podSelector":{"matchLabels":{"k8s-app":"kube-dns"}}}]` | NetworkPolicyPeers of the cluster DNS servers. |
| networkPolicy.enabled | bool | `false` | Render a default-deny networking.k8s.io/v1 NetworkPolicy. DNS egress is allowed to `networkPolicy.dns.to` on `networkPolicy.dns.ports`. |
| networkPolicy.extraEgress | list | `[]` | Raw NetworkPolicyEgressRules appended to the policy. |
| networkPolicy.ingressFrom | list | `[]` | NetworkPolicyPeers (e.g. the Ingress controller pods) allowed to reach the web port. Empty blocks all ingress except node-local kubelet probes (allowed by most CNIs). |
| nodeSelector | object | `{}` | Node selector. |
| podAnnotations | object | `{}` | Pod annotations. |
| podDisruptionBudget.enabled | bool | `true` | Render a PodDisruptionBudget. Skipped when the effective replica count (`autoscaling.minReplicas` with autoscaling, else `replicaCount`) is 1, as it would block every node drain. |
| podDisruptionBudget.minAvailable | int | `1` | Minimum available pods during voluntary disruptions. |
| podLabels | object | `{}` | Extra pod labels. |
| podSecurityContext | object | `{"fsGroup":101,"runAsGroup":101,"runAsNonRoot":true,"runAsUser":101,"seccompProfile":{"type":"RuntimeDefault"}}` | Pod security context. |
| port | int | `8080` | nginx listen port baked into the image. |
| preStopSleepSeconds | int | `5` | Seconds the pod keeps serving after it is removed from endpoints, so Ingress controllers stop routing before SIGTERM. |
| probes | object | `{"liveness":{"failureThreshold":3,"periodSeconds":10,"timeoutSeconds":2},"readiness":{"failureThreshold":3,"periodSeconds":5,"timeoutSeconds":2}}` | Probe timings (both use `/healthz`). |
| replicaCount | int | `2` | Replicas (ignored when `autoscaling.enabled`). |
| requireImageDigest | bool | `false` | Fail rendering unless `image.digest` is set. Recommended for production. |
| resources | object | `{"limits":{"memory":"128Mi"},"requests":{"cpu":"10m","memory":"32Mi"}}` | Container resources. |
| securityContext | object | `{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]},"readOnlyRootFilesystem":true,"runAsGroup":101,"runAsNonRoot":true,"runAsUser":101,"seccompProfile":{"type":"RuntimeDefault"}}` | Container security context. |
| service.port | int | `8080` | Service port. |
| service.type | string | `"ClusterIP"` | Service type. |
| serviceAccount.annotations | object | `{}` | ServiceAccount annotations. |
| serviceAccount.create | bool | `true` | Create a dedicated ServiceAccount. Its token is never mounted. |
| serviceAccount.name | string | `""` | ServiceAccount name; defaults to the full name when empty. |
| terminationGracePeriodSeconds | int | `30` | Pod termination grace period. |
| tmpSizeLimit | string | `"64Mi"` | Size limit of the /tmp emptyDir (nginx pid file and temp buffers). |
| tolerations | list | `[]` | Tolerations. |
| topologySpreadConstraints | list | `[{"maxSkew":1,"topologyKey":"kubernetes.io/hostname","whenUnsatisfiable":"ScheduleAnyway"}]` | Topology spread constraints. A `labelSelector` matching the pods is added when omitted. |
