# k8s-autoscaling-patterns-demo

## 1) Project Overview

Most autoscaling mistakes are signal mistakes.  
This repository is a side-by-side systems comparison of two valid but different pressure signals.

**Autoscaling should follow workload pressure, not convenience.**

The same system under load can behave very differently depending on whether scaling follows CPU or backlog.

- **Demo 1** uses native Kubernetes HPA on CPU for a synchronous, CPU-heavy Go service  
- **Demo 2** uses KEDA on lag (backlog) for an asynchronous, event-driven consumer workload  

The core contrast is simple: CPU reflects compute pressure; lag (backlog) reflects queue pressure.

---

## 2) Why I Built It

I built this as a practical system-design exercise around autoscaling signals.

Teams often default to CPU-based HPA everywhere, but distributed workloads do not present pressure in one uniform way. These demos make the trade-offs observable: signal choice changes latency, throughput behavior, and cost under load.

---

## 3) Demo Comparison

| Pattern | Workload | Scaling Signal | Best Fit | Main Weakness |
|---|---|---|---|---|
| Demo 1: Native HPA on CPU | Synchronous, CPU-heavy Go service | Pod CPU utilization | Stateless compute-heavy APIs/services | Can miss queued pressure and upstream backlog |
| Demo 2: KEDA on lag (backlog) | Asynchronous event-driven consumer workload | Lag (backlog) | Consumer fleets draining queued work | Effective scaling still constrained by partition count and broker wiring |

CPU tells you how busy your service is. Lag tells you whether your system is keeping up with incoming work.  
The practical rule is simple: autoscaling should follow workload pressure, not convenience.

---

## 4) Short Architecture Overview

- Demo 1: clients call a Go API, work is processed inline, and HPA scales pods from CPU usage  
- Demo 2: a producer publishes events, a consumer deployment processes messages, and KEDA scales consumers from lag (backlog)  

Both demos run on Kubernetes and are intentionally small so behavior is easy to observe.

---

### Demo 1: CPU HPA

Steady state, initial scale-up (then plateau as average CPU drops across replicas), further scale-up under stronger sustained load, and scale-down after load eases.

![Demo 1: before load](docs/screenshots/demo1-before-load.png)
![Demo 1: first scale-up](docs/screenshots/demo1-scale-up-1.png)
![Demo 1: second scale-up](docs/screenshots/demo1-scale-up-2.png)
![Demo 1: scale-down](docs/screenshots/demo1-scale-down.png)

---

### Demo 2: lag (backlog) scaling

Low backlog, then scale-out as consumer lag grows (the system is falling behind), then scale-down after the backlog is drained.  
Scale-down typically lags scale-up due to cooldown periods and HPA stabilization behavior.

![Demo 2: before load](docs/screenshots/demo2-before-load.png)
![Demo 2: scale-up](docs/screenshots/demo2-scale-up.png)
![Demo 2: scale-down](docs/screenshots/demo2-scale-down.png)

---

## 5) Key Lessons Learned

- CPU is a strong default for synchronous compute-heavy services  
- Lag (backlog) is a better signal for asynchronous consumers  
- Signal mismatch causes under-scaling (latency/backlog growth) or over-scaling (waste)  
- Consumer scaling for a single group is **bounded by partition count**: each partition can be consumed by only one consumer at a time, so insufficient partitions cap useful parallelism regardless of autoscaler configuration  
- Autoscaling effectiveness is constrained by system design choices (such as partitioning), not just autoscaler configuration  
- Small, observable, deterministic demos are effective for validating platform decisions  

---

## 6) Repository Structure

```text
k8s-autoscaling-patterns-demo/
  README.md
  LICENSE
  .gitignore
  docs/
    architecture-overview.md
    screenshots/
    diagrams/
  demo-1-cpu-hpa/
  demo-2-redpanda-keda/
```

---

## 7) How to Get Started

1. Pick a local Kubernetes environment (for example, kind)  
2. Run Demo 1 using `demo-1-cpu-hpa/README.md`  
3. Run Demo 2 using `demo-2-redpanda-keda/README.md`  
4. Compare scaling behavior under load:
   - Demo 1 responds to CPU pressure  
   - Demo 2 responds to queue lag  

---

## 8) Observability

These demos intentionally rely on lightweight runtime signals instead of full dashboards.

For this scope, `kubectl get pods`, `kubectl get hpa`, `kubectl describe scaledobject`, and consumer logs are sufficient to verify health, pressure, and scaling behavior end to end.

This keeps signal interpretation explicit during system-design discussion.

---

## 9) Versions Used

Documented in-repo where it matters for builds; cluster and add-ons are intentionally not pinned so you can run on a current local Kubernetes.

- **Go:** `1.22` (`demo-1-cpu-hpa/go.mod`); `1.24` (`demo-2-redpanda-keda/go.mod`)  
- **Kubernetes / kind:** Not pinned; use a version supported by your kind release  
- **KEDA:** Installed via Helm (see demo README); version depends on your environment  
- **Redpanda:** Uses `latest` image; pin a digest if strict reproducibility is required  
- **metrics-server:** Required for Demo 1; install via upstream Kubernetes SIG manifest  

Version skew across broker, clients, autoscaler, and the API server can cause subtle failures and is worth validating after upgrades.

---

## 10) Why This Matters

Modern systems combine synchronous APIs and asynchronous pipelines.

Autoscaling is therefore a **control-loop design problem**, not just a Kubernetes configuration detail. Choosing the right signal directly impacts:

- system responsiveness  
- cost efficiency  
- behavior under bursty load  

This project keeps the system intentionally small so these trade-offs remain easy to observe and reason about.

---

## 11) How to Think About This Project

This project highlights a practical design choice in autoscaling: selecting the right signal for the workload.

CPU is a good proxy for synchronous, compute-bound request paths, where work is processed inline.

For asynchronous systems, backlog (consumer lag) is often a more accurate signal, because it reflects whether the system is keeping up with incoming work.

Choosing the wrong signal leads to predictable behavior:

- under-scaling → growing latency and backlog  
- over-scaling → increased cost without improving throughput  

The goal of this project is to make these trade-offs observable in a simple, controlled environment.

---

## 12) Operational Trade-offs

In real systems, choosing the wrong autoscaling signal creates predictable failure modes.

CPU-based autoscaling is simple and often correct for synchronous compute paths (Demo 1), but it can miss queue pressure in asynchronous pipelines (Demo 2).

When consumer fleets are under-scaled, backlog grows and end-to-end processing delay increases.

When they are over-scaled, cost rises without equivalent throughput gain, especially when partition limits cap useful parallelism.

Signal choice is therefore not a tuning detail; it is a first-order design decision that shapes responsiveness and cost efficiency.

---

## 13) What I Learned

- Autoscaling quality is bounded by metric quality  
- CPU is a reliable proxy for synchronous compute-heavy pressure, but often a weak proxy for queue pressure  
- Lag/backlog is usually the more meaningful signal for asynchronous consumers  
- HPA/KEDA behavior depends on configuration details, not only thresholds  
- Consumer scaling has hard limits from partition count, so throughput gains are not always linear  
- AI-assisted implementation accelerated iteration, but required strict control to avoid configuration drift  

---

## 14) Why This Project Is Interesting

This repository focuses on a real system design decision: choosing the correct autoscaling signal for different workload shapes.

It contrasts synchronous CPU-bound behavior with asynchronous queue-driven behavior and shows why those paths require different scaling logic.

It also demonstrates how scaling, service discovery, and broker behavior interact in practice.

Implementation debugging is treated as part of system design, not a separate concern.

---

This repository is a learning and demonstration project, not a production-ready platform blueprint.
