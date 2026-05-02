# Demo 1: CPU HPA (Synchronous Go Service)

## Overview

This demo is a synchronous, CPU-heavy Go service running on Kubernetes. It uses native Kubernetes HorizontalPodAutoscaler (HPA) to scale pods based on CPU utilization.

This demo models a compute-bound, stateless request path and uses CPU-driven HPA as the scaling signal, so you can reason about how that choice behaves under sustained load.

---

## Comparison Context

| Pattern | Workload | Scaling signal | Best fit | Main weakness |
|---|---|---|---|---|
| Demo 1: native HPA on CPU | Synchronous, CPU-heavy Go service | Pod CPU utilization | Stateless, compute-heavy APIs and services | Weak signal for queue- or backlog-driven pressure |
| Demo 2: KEDA on lag (backlog) | Asynchronous, event-driven consumer workload | Lag (backlog) | Consumer fleets draining queued work | Depends on broker, topic, and group correctness; bounded by partition parallelism |

**Key idea:** autoscaling should follow real workload pressure, not just convenient signals like CPU.  
This demo uses CPU because compute is the direct bottleneck in the synchronous request path.

---

## Architecture

```text
Client / Load Generator
        |
        v
   Service (HTTP)
        |
        v
Synchronous CPU-bound work
        |
        v
Deployment + Service + HPA (CPU)
```

---

## Components

- `cmd/server`: HTTP service
- `cmd/loadgen`: local load generator
- `k8s/deployment.yaml`: deployment with CPU requests/limits
- `k8s/service.yaml`: ClusterIP service
- `k8s/hpa.yaml`: HPA targeting CPU utilization

Primary endpoints:

- `GET /health`
- `POST /work`
- `GET /stats`
- `GET /metrics`

---

## Why CPU Is the Scaling Signal Here

- Work is synchronous and CPU-bound, so CPU usage directly reflects pressure.
- HPA on CPU is native to Kubernetes and operationally simple.
- For stateless compute-heavy services, CPU is often the correct default signal.
- HPA reacts over time based on metric windows; it is not instantaneous.
- Correct CPU requests are critical—poor requests lead to noisy or misleading scaling behavior.

---

## How to Run Locally (kind)

For the full automated reviewer flow across both demos, run `./scripts/run-autoscaling-demo.sh` from the repository root.

Prerequisites: kind cluster + `metrics-server`.

```bash
docker build -t demo-1-cpu-hpa:latest .
kind load docker-image demo-1-cpu-hpa:latest

kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml

kubectl get deploy,svc,hpa
kubectl get pods
```

Port-forward:

```bash
kubectl port-forward svc/demo-1-cpu-hpa 8080:80
```

### App tests

From the repository root, `./scripts/test-apps.sh` runs `go test` and `go vet` for both demos. From this directory you can run `go test ./...` (no Kubernetes required).

---

## How to Validate Scaling

Generate CPU-heavy load:

```bash
go run ./cmd/loadgen --target http://localhost:8080/work --total 3000 --concurrency 50 --workUnits 300000
```

Observe scaling:

```bash
kubectl get hpa -w
kubectl get pods -w
```

Expected behavior:

- Initial sustained load triggers scale-up
- After replicas increase, average CPU may drop → scaling can plateau
- Stronger sustained load triggers additional scale-up
- After load stops, scale-down is gradual (not immediate)

Quick checks:

```bash
curl -sS http://localhost:8080/health
curl -sS http://localhost:8080/stats
```

---

## Scaling Behavior Snapshots

Initial sustained load drives the first scale-up.  
After replicas increase, **average CPU across pods decreases**, which can pause further scaling.  
A stronger sustained load wave triggers additional scale-up—expected behavior for CPU-based HPA.

![Demo 1: before load](../docs/screenshots/demo1-before-load.png)
![Demo 1: first scale-up](../docs/screenshots/demo1-scale-up-1.png)
![Demo 1: second scale-up](../docs/screenshots/demo1-scale-up-2.png)
![Demo 1: scale-down](../docs/screenshots/demo1-scale-down.png)

---

## Observability

This demo intentionally relies on simple runtime signals:

- `kubectl get pods`
- `kubectl get hpa -w`
- service stats and logs

These are sufficient to reason about pressure, scaling decisions, and recovery behavior without a full observability stack.

---

## Runtime Behavior

- low load keeps replicas near the minimum
- sustained CPU pressure triggers HPA scale-up
- after replicas increase, average CPU can drop and scaling may plateau
- additional sustained load can trigger further scale-up
- scale-down is gradual because HPA avoids immediate downscaling
- CPU requests strongly influence scaling sensitivity and timing

---

## Operational Trade-offs

CPU-based autoscaling is simple and effective for synchronous compute paths.

However, it does not capture pressure outside the service itself.  
If work shifts into queues or upstream systems, CPU may remain low while latency increases.

This makes CPU a strong signal for inline processing, but a weak signal for asynchronous pipelines.

---

## Engineering Takeaways

- autoscaling quality depends directly on signal quality
- CPU is a useful signal for synchronous, compute-bound request paths
- HPA behavior is shaped by resource requests, metric windows, and stabilization behavior
- CPU becomes a weak signal when pressure moves outside the service, such as into queues or upstream systems

---

## Scope Boundaries

- single-signal autoscaling (CPU only); no queue or backlog signal
- no modeling of upstream/downstream latency or external bottlenecks beyond this service
- manifests and tuning target a focused local validation loop, not production sizing or SLO guarantees
- omits optional production controls (for example PDBs, topology spread, advanced rollout policy)
