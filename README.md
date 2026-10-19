# Biashara OS — Practical Kubernetes Deployment

Apply-ready Kubernetes manifests, container recipe, and operator scripts that
reproduce the homelab deployment of **Biashara OS v0.2.0** (Africa-first
manufacturing ERP MVP) described in [`docs/Biashara_OS_Full_Journey_Cleaned.pdf`](docs/Biashara_OS_Full_Journey_Cleaned.pdf).

> This repo is the "do this again on a fresh cluster" companion to that
> journey. The PDF is the chronological log — what happened, what broke, how
> each piece was validated. The YAML here is the finished, reproducible shape.

---

## Topology

| Role              | Host             | Network                | Responsibility                                     |
| ----------------- | ---------------- | ---------------------- | -------------------------------------------------- |
| control plane     | `kubes`          | 192.168.30.134 / VLAN 30 | kubeadm API server · Traefik ingress controller    |
| worker            | `deploy`         | 192.168.50.172 / VLAN 50 | containerd + Calico · Biashara OS Pod · SQLite PV  |
| object storage    | `s3bucket` (LXC) | 192.168.30.147 / VLAN 30 | MinIO S3 API :9000 · console :9001 · private bucket `biasharaos-uploads` |
| Pod network       | Calico           | 10.244.0.0/16          | IPIP encapsulation + egress NAT                    |

```
                        ┌──────────────────────────┐
                        │ browser / workstation    │
                        │ http://biasharaos.home   │
                        └────────────┬─────────────┘
                                     │  (Host header)
                        ┌────────────▼─────────────┐
                        │ Traefik Ingress (kubes)  │
                        └────────────┬─────────────┘
                                     │ ClusterIP :80 → :3000
                        ┌────────────▼─────────────┐
                        │ biasharaos Pod (deploy)  │─── /app/data (SQLite PV)
                        └────────────┬─────────────┘
                                     │ S3 PutObject
                        ┌────────────▼─────────────┐
                        │ MinIO :9000 (s3bucket)   │
                        │ bucket: biasharaos-uploads│
                        └──────────────────────────┘
```

---

## Repo layout

```
.
├── app/
│   └── Dockerfile                       Node 24-slim + @aws-sdk/client-s3 (matches PDF §12)
├── docs/
│   └── deployment-journey.pdf           The 17-page build/debug chronicle
├── k8s/
│   ├── namespace.yaml                   biasharaos
│   ├── persistentvolume.yaml            Local hostPath PV pinned to `deploy`
│   ├── persistentvolumeclaim.yaml       Binds the PV to the Deployment
│   ├── secret-s3.example.yaml           Shape of biasharaos-s3  (do not apply as-is)
│   ├── secret-invoice-token.example.yaml Shape of biasharaos-invoice-token
│   ├── service.yaml                     ClusterIP :80 → :3000
│   ├── ingress.yaml                     Traefik Ingress, host biasharaos.home
│   └── deployment.yaml                  1 replica, Recreate, nodeSelector: deploy
├── scripts/
│   ├── bootstrap.sh                     Fresh-install prereqs (swap off, modprobe, sysctl)
│   ├── build-and-load-image.sh          podman build → ctr -n k8s.io images import on worker
│   ├── create-secrets.sh                Materialises both Secrets from .env
│   └── smoke-test.sh                    Ingress + /api/invoices/upload end-to-end
├── Makefile                             make apply · secrets · rollout · logs · smoke
├── .env.example                         Shape of the local .env (git-ignored)
├── .gitignore
├── LICENSE                              MIT
└── README.md                            you are here
```

---

## Prerequisites

- A Kubernetes cluster (v1.30+ works; the recorded cluster was v1.36.x).
- A worker node labelled with `kubernetes.io/hostname=deploy` (the hostname is
  significant — change it in both `persistentvolume.yaml` and `deployment.yaml`
  if your worker is called something else).
- Traefik installed in namespace `traefik` with `IngressClass` name `traefik`.
- Access to the Biashara OS source code (`socilate47` / `Jamo642` repo
  `biasharaos`) checked out on the worker.
- MinIO (or any S3-compatible object store) reachable from Pod network.
- `podman` on the worker to build the image (containerd ships without a build
  tool). `kubectl` + `openssl` on the host where you run `make secrets`.

> ⚠ The `scripts/bootstrap.sh`, `kubeadm init`, `kubeadm join`, Calico install,
> and MinIO install steps are **documentation**, not idempotent operations.
> Running them on an already-running cluster will break it. See the PDF for
> the full history and the reasoning behind each one.

---

## Deploy — the short version

```bash
# 1. On the WORKER (deploy): build the image and load it into containerd.
#    This is what makes `imagePullPolicy: Never` work.
SRC_DIR=~/biasharaos make build-image

# 2. On a host with kubectl: copy and fill the env, create Secrets.
cp .env.example .env
# edit .env — fill AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, S3_ENDPOINT, etc.
make secrets

# 3. Apply the stack and wait for rollout.
make apply
make rollout
make status
```

Add `biasharaos.home` to your laptop's `/etc/hosts` pointing at the control
plane IP (`192.168.30.134`) and open <http://biasharaos.home>.

---

## Deploy — step-by-step with the reasoning

### 1. Namespace, PV, PVC

The `biasharaos` namespace isolates the workload. The `biasharaos-sqlite-pv`
PersistentVolume is a `hostPath` volume pinned to the worker node via
`nodeAffinity` on `kubernetes.io/hostname=deploy`. The PVC binds to it by name
(`volumeName: biasharaos-sqlite-pv`) so no dynamic provisioner ever surprises
you. Reclaim policy is `Retain` — deleting the PVC will not wipe business data.

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/persistentvolume.yaml
kubectl apply -f k8s/persistentvolumeclaim.yaml
kubectl get pv,pvc -n biasharaos -o wide
```

### 2. Secrets (two of them)

The app expects six S3 env vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
`AWS_REGION`, `S3_ENDPOINT`, `S3_BUCKET`, `S3_FORCE_PATH_STYLE`) and one upload
auth token (`INVOICE_UPLOAD_TOKEN`). They live in **two** separate Secrets so
you can rotate the upload token without re-shipping the S3 keys.

```bash
cp .env.example .env         # fill in values
./scripts/create-secrets.sh  # creates biasharaos-s3 and biasharaos-invoice-token
kubectl get secret -n biasharaos
```

The script runs `kubectl create secret --dry-run=client -o yaml | kubectl apply`
so repeat runs are idempotent (an update, not a conflict). It never prints the
token value; retrieve it with:

```bash
kubectl get secret biasharaos-invoice-token -n biasharaos \
  -o jsonpath='{.data.INVOICE_UPLOAD_TOKEN}' | base64 -d
```

### 3. Service + Ingress

Service is a vanilla `ClusterIP` (`:80 → :3000`). Ingress is a standard
`networking.k8s.io/v1` resource with `ingressClassName: traefik` and a Host
rule for `biasharaos.home`. The entrypoint annotation (`web`) matches the
default Traefik HTTP entrypoint.

```bash
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/ingress.yaml
kubectl get svc,ing -n biasharaos
```

### 4. Deployment

Three design choices worth highlighting:

- **`strategy: Recreate`** — SQLite tolerates exactly one writer. A rolling
  update that briefly runs two Pods will corrupt the DB. During rollouts the
  old Pod drains fully before the new one starts.
- **`replicas: 1` + `nodeSelector: kubernetes.io/hostname=deploy`** — the PV is
  local to that worker, so the Pod must land there.
- **`imagePullPolicy: Never`** — the image was built on the worker with Podman
  and imported into containerd. There is no registry; kubelet must not pull.

```bash
kubectl apply -f k8s/deployment.yaml
kubectl rollout status deployment/biasharaos -n biasharaos --timeout=180s
```

### 5. Build & load the image

Containerd and Podman have separate image stores. The script bridges them:

```bash
# on worker `deploy`
SRC_DIR=~/biasharaos VERSION=0.2.0 ./scripts/build-and-load-image.sh
# -> podman build -> podman save --format docker-archive
# -> sudo ctr -n k8s.io images import  (k8s.io is kubelet's namespace)
```

To swap in a new image after a change:

```bash
kubectl set image deployment/biasharaos \
  biasharaos=localhost/biasharaos:0.2.1 -n biasharaos
make rollout
```

### 6. Verify

```bash
make smoke
# or manually:
curl -I -H "Host: biasharaos.home" http://192.168.30.134/
# expect: HTTP/1.1 200 OK
```

Upload a test PDF directly:

```bash
TOKEN=$(kubectl get secret biasharaos-invoice-token -n biasharaos \
          -o jsonpath='{.data.INVOICE_UPLOAD_TOKEN}' | base64 -d)
curl -i -X POST http://192.168.30.134/api/invoices/upload \
  -H "Host: biasharaos.home" \
  -H "x-upload-token: $TOKEN" \
  -H "Content-Type: application/pdf" \
  --data-binary @/path/to/invoice.pdf
# expect: HTTP/1.1 201 Created { "key": "invoices/<uuid>.pdf" }
unset TOKEN
```

Confirm the object is really in MinIO:

```bash
# on s3bucket, with a configured mc alias
mc ls local/biasharaos-uploads/invoices/
```

---

## Operational playbook

| What               | How                                                                         |
| ------------------ | --------------------------------------------------------------------------- |
| Tail live logs     | `make logs`                                                                 |
| Overall status     | `make status`                                                               |
| Change env vars    | Edit `.env` → `make secrets` → `kubectl rollout restart deployment/biasharaos -n biasharaos` |
| Deploy new image   | `make build-image IMAGE_VERSION=0.2.1` → `kubectl set image …` → `make rollout` |
| Clean teardown     | `make delete` (keeps the PV + namespace so data survives)                   |
| Nuclear teardown   | `make delete && kubectl delete ns biasharaos && kubectl delete pv biasharaos-sqlite-pv` (then wipe `/var/lib/biasharaos/sqlite` on the worker) |

---

## Known lessons from the deployment journey

Pulled from [`docs/Biashara_OS_Full_Journey_Cleaned.pdf`](docs/Biashara_OS_Full_Journey_Cleaned.pdf) so you
don't have to re-learn them:

1. **Calico IP pool overlap** (§4) — the obsolete `default-ipv4-ippool` had
   `192.168.30.0/24`, overlapping the physical VLAN 30 subnet, which broke
   Pod→MinIO egress. Verify no workload uses the old pool before removing it:
   `kubectl delete ippool default-ipv4-ippool`.
2. **AppArmor stalled Pod shutdown** (§11) — a `cri-containerd.apparmor.d`
   profile from a MicroK8s machine was reused on a kubeadm host; it lacked a
   `signal (receive) peer=runc` rule, so `kubectl rollout` timed out with
   `KillContainerError`. Fix is a scoped `apparmor_parser -r` of that one
   profile, not disabling AppArmor globally.
3. **Dockerfile missed `npm ci`** (§12) — the first image didn't ship
   `@aws-sdk/client-s3`, so the invoice upload route exploded at runtime. The
   `app/Dockerfile` in this repo installs production deps explicitly.
4. **Secret rotation triggers a rollout** — `kubectl set env … --from=secret/…`
   writes a Pod template change. With `Recreate`, the old Pod drains first.

---

## Security notes

- No real secrets live in this repo. The `.example.yaml` files are shape-only
  templates with `REPLACE_ME` placeholders.
- `.env` is `.gitignored`. Keep it out of commits.
- `INVOICE_UPLOAD_TOKEN` is compared constant-time server-side.
- The lab uses plain HTTP. TLS termination is a separate concern (cert-manager
  + a self-signed CA is the natural next step).
- The MinIO service account `biasharaos-app` should have `s3:ListBucket`,
  `s3:GetObject`, `s3:PutObject` on `biasharaos-uploads/*` and no delete rights
  — matches the recorded policy intent in PDF §9.

---

## License

MIT — see [LICENSE](LICENSE).
