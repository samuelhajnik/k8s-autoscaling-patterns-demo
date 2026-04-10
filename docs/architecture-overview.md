# Architecture Overview

This repository demonstrates two autoscaling patterns side by side so signal choice is easy to compare.

## Demo 1 (CPU HPA): Synchronous Path

```text
Load Generator
    -> Go Service
    -> CPU-bound work
    -> HPA scales on CPU utilization
```

### Component Roles

- **Load Generator**: sends synchronous requests.
- **Go Service**: handles requests and does CPU-heavy processing inline.
- **CPU work**: directly drives pod CPU usage.
- **HPA on CPU**: increases/decreases replicas from observed CPU metrics.

## Demo 2 (Redpanda + KEDA): Asynchronous Path

```text
Load Generator
    -> Producer
    -> Redpanda topic
    -> Consumer Deployment
    -> KEDA scales on lag (backlog)
```

### Component Roles

- **Load Generator**: triggers producer traffic bursts.
- **Producer**: publishes messages to the topic.
- **Redpanda topic**: buffers queued work.
- **Consumer Deployment**: processes queued messages.
- **KEDA on lag**: scales consumers from backlog in the topic.

## Why the Scaling Signals Differ

- **Demo 1 uses CPU** because the workload is synchronous and compute-heavy; CPU closely tracks pressure.
- **Demo 2 uses lag (backlog)** because the workload is queue-driven; pending work in the broker is a stronger signal than consumer CPU alone.

## Core Interview Comparison

Use this framing:

- Architecture should drive signal choice.
- For synchronous stateless compute services, CPU is a simple native default.
- For asynchronous event-driven consumers, lag (backlog) is often more meaningful.
- The key engineering lesson: **match autoscaling signals to workload shape**, not just to platform defaults.
