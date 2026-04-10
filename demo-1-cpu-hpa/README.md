# Demo 1: CPU HPA (Synchronous Go Service)

## 1) Overview

This demo is a synchronous, CPU-heavy Go service running on Kubernetes. It uses native Kubernetes HorizontalPodAutoscaler (HPA) to scale pods based on CPU utilization.

The goal is to treat CPU-driven HPA as a deliberate design choice for compute-bound stateless services and to observe its behavior under sustained load.

---

## 2) Comparison Context

| Pattern | Workload | Scaling Signal | Best Fit | Main Weakness |
|---|---|---|---|---|
| Demo 1: Native HPA on CPU | Synchronous, CPU-heavy Go service | Pod CPU utilization | Stateless compute-heavy APIs/services | Weak signal for queued/backlog-driven pressure |
| Demo 2: KEDA on lag (backlog) | Asynchronous event-driven consumer workload | Lag (backlog) | Consumer fleets draining queued work | Depends on broker/topic/group correctness and partition parallelism limits |

**Key idea:** autoscaling should follow real workload pressure, not just convenient signals like CPU.  
This demo uses CPU because compute is the direct bottleneck in the synchronous request path.

---

## 3) Architecture

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

## 4) Components

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

## 5) Why CPU Is the Scaling Signal Here

- Work is synchronous and CPU-bound, so CPU usage directly reflects pressure.
- HPA on CPU is native to Kubernetes and operationally simple.
- For stateless compute-heavy services, CPU is often the correct default signal.
- HPA reacts over time based on metric windows; it is not instantaneous.
- Correct CPU requests are critical—poor requests lead to noisy or misleading scaling behavior.

---

## 6) How to Run Locally (kind)

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

---

## 7) How to Validate Scaling

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

### Scaling Behavior (Snapshots)

Initial sustained load drives the first scale-up.  
After replicas increase, **average CPU across pods decreases**, which can pause further scaling.  
A stronger sustained load wave triggers additional scale-up—expected behavior for CPU-based HPA.

![Demo 1: before load](../docs/screenshots/demo1-before-load.png)
![Demo 1: first scale-up](../docs/screenshots/demo1-scale-up-1.png)
![Demo 1: second scale-up](../docs/screenshots/demo1-scale-up-2.png)
![Demo 1: scale-down](../docs/screenshots/demo1-scale-down.png)

---

## 8) Observability

This demo intentionally relies on simple runtime signals:

- `kubectl get pods`
- `kubectl get hpa -w`
- service stats and logs

These are sufficient to reason about pressure, scaling decisions, and recovery behavior without a full observability stack.

---

## 9) What I Observed

- At low load, replicas stay near minimum
- Sustained load increases CPU and triggers scale-up
- After scaling, average CPU drops and scaling may pause
- Additional sustained load triggers further scale-up
- Scale-down happens gradually after load decreases
- CPU requests significantly affect scaling sensitivity and timing

---

## 10) Limitations

- Single-signal autoscaling (CPU only)
- No awareness of queue/backlog pressure
- Local demo tuning, not production sizing
- No advanced resiliency controls (e.g. PDBs, multi-zone placement)

---

## 11) Operational Trade-offs

CPU-based autoscaling is simple and effective for synchronous compute paths.

However, it does not capture pressure outside the service itself.  
If work shifts into queues or upstream systems, CPU may remain low while latency increases.

This makes CPU a strong signal for inline processing, but a weak signal for asynchronous pipelines.

---

## 12) What I Learned

- Autoscaling quality depends directly on signal quality
- CPU is a reliable proxy for synchronous compute-heavy pressure
- HPA behavior is shaped by resource requests and stabilization windows, not just target values
- CPU becomes a weak signal when pressure moves to queues
- Clear configuration and a single source of truth were essential to avoid drift during iteration
