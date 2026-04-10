# Demo 2: Redpanda + KEDA Lag Flow

```mermaid
flowchart LR
    LG[Load Generator] --> P[Producer]
    P --> R[Redpanda Topic]
    R --> C[Consumer Deployment]
    KEDA[KEDA] -. watches lag (backlog) .-> R
    KEDA -. scales .-> C
```

This demo models an asynchronous event-driven pipeline.
Producer traffic creates queued work in Redpanda, then consumers drain the backlog.
KEDA watches lag (backlog) and scales the consumer deployment accordingly.
For queue-driven systems, lag is often a stronger scaling signal than CPU.
