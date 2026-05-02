# Screenshots index

Captured HPA / deployment views while running the demos locally. Paths are relative to the repo root.

## Demo 1 (CPU HPA)

| File | What it shows |
|------|----------------|
| `demo1-before-load.png` | Steady state: low load, minimal replicas. |
| `demo1-scale-up-1.png` | First scale-up from sustained load; often followed by a plateau as average CPU drops across replicas. |
| `demo1-scale-up-2.png` | Second scale-up after stronger sustained load. |
| `demo1-scale-down.png` | Replicas decreasing after load eases. |

## Demo 2 (Redpanda + KEDA)

| File | What it shows |
|------|----------------|
| `demo2-before-load.png` | Steady state: low backlog, consumer at minimum replicas. |
| `demo2-scale-up.png` | Scale-out as lag (backlog) crosses the trigger threshold. |
| `demo2-scale-down.png` | Scale-in as backlog drains (timing reflects cooldown / stabilization). |

## Automated demo validation (kind)

| File | What it shows |
|------|---------------|
| `autoscaling-validation-summary.png` | End-to-end kind validation showing Demo 1 HPA scale-up/down and Demo 2 KEDA lag-driven scale-up/down. |
