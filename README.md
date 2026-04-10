# Kubernetes Autoscaling Patterns Demo

## What this repo demonstrates

This project shows a practical comparison of two fundamentally different autoscaling strategies:

- **CPU-based HPA** → suitable for synchronous, compute-bound workloads  
- **Lag-based scaling (KEDA)** → suitable for asynchronous, event-driven systems  

The goal is not to show *how to autoscale*, but to demonstrate **how choosing the wrong signal leads to incorrect scaling behavior**.

---

## Why this matters

Autoscaling is often treated as a configuration problem.

In reality, it is a **system design decision**:

- Wrong signal → under-scaling or over-scaling  
- Correct signal → predictable and efficient scaling  

---

## The two demos

### 1. CPU-based autoscaling (HPA)

- Workload: synchronous request/response (Go service)
- Scaling signal: CPU utilization
- Behavior:
  - Scales based on compute pressure
  - Works well when load directly translates to CPU usage

### 2. Lag-based autoscaling (KEDA)

- Workload: async message processing (event-driven consumer)
- Scaling signal: queue lag (backlog)
- Behavior:
  - Scales based on backlog
  - Decouples producers from consumers
  - Reflects *real system pressure*, not just CPU

---

## Quick start (reviewer path)

1. Run CPU-based demo
2. Observe pod scaling under load
3. Run lag-based demo
4. Observe queue lag vs scaling behavior
5. Compare:
   - Response time
   - Backlog growth
   - Scaling patterns

---

## What you should observe

- CPU scaling reacts to **current load**
- Lag-based scaling reacts to **accumulated pressure**
- Async systems require different signals than sync systems

---

## Demo behavior (visualized)

### CPU HPA

Steady state, initial scale-up, plateau as CPU averages out, further scale-up under sustained load, and scale-down when load drops.

![Demo 1: before load](docs/screenshots/demo1-before-load.png)
![Demo 1: first scale-up](docs/screenshots/demo1-scale-up-1.png)
![Demo 1: second scale-up](docs/screenshots/demo1-scale-up-2.png)
![Demo 1: scale-down](docs/screenshots/demo1-scale-down.png)

---

### Lag (backlog) scaling

Low backlog initially, then scale-out as lag grows, followed by scale-down after backlog is drained.

![Demo 2: before load](docs/screenshots/demo2-before-load.png)
![Demo 2: scale-up](docs/screenshots/demo2-scale-up.png)
![Demo 2: scale-down](docs/screenshots/demo2-scale-down.png)

---

## Key trade-offs & lessons

### 1. CPU is not a universal signal
- Works for synchronous workloads
- Fails for async systems where backlog matters more

### 2. Lag reflects real system pressure
- Captures delayed processing
- Enables more accurate scaling decisions

### 3. Partitioning limits scaling
- Consumers scale only up to partition count
- Hot partitions can become bottlenecks

### 4. Latency vs throughput trade-off
- CPU scaling → lower latency (reactive)
- Lag scaling → better throughput (buffered)

### 5. Autoscaling is constrained by system design
- Scaling effectiveness depends on partitioning, workload shape, and architecture
- Autoscaler configuration alone cannot fix poor system design

---

## Architecture overview

- Demo 1: clients call a Go API, work is processed inline, HPA scales based on CPU  
- Demo 2: producer publishes events, consumers process messages, KEDA scales based on lag  

Both demos run on Kubernetes and are intentionally small so behavior is easy to observe.

---

## How to get started

1. Use a local Kubernetes environment (e.g. kind)
2. Run Demo 1 (`demo-1-cpu-hpa`)
3. Run Demo 2 (`demo-2-redpanda-keda`)
4. Compare scaling behavior under load

---

## Observability

You can verify behavior using simple tools:

- `kubectl get pods`
- `kubectl get hpa`
- `kubectl describe scaledobject`
- consumer logs

This keeps system behavior transparent during analysis.

---

## Repo structure

```
k8s-autoscaling-patterns-demo/
  README.md
  docs/
    screenshots/
  demo-1-cpu-hpa/
  demo-2-redpanda-keda/
```

---

## Summary

This demo highlights a core distributed systems principle:

> Autoscaling is not about Kubernetes configuration —  
> it is about choosing the correct signal for your system.

If the signal is wrong, scaling will be wrong — no matter how well it is configured.
