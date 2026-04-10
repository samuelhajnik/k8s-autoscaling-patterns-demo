# Demo 2 Design: Redpanda + KEDA Lag-Based Autoscaling

## Goal
Demonstrate lag-based autoscaling for an asynchronous event-driven workload in Kubernetes.

This demo must show:
- a broker running in Kubernetes
- a producer service publishing messages
- a consumer deployment processing messages
- KEDA scaling the consumer based on backlog / lag
- clear contrast with Demo 1 (CPU-based HPA)

## Namespace
demo-2-redpanda-keda

## Broker
Use Redpanda as a Kafka-compatible broker.

### Broker service DNS
redpanda.demo-2-redpanda-keda.svc.cluster.local:9092

### In-namespace short name
redpanda:9092

## Topic
demo-work

## Consumer group
demo-work-consumer-group

## Producer
### Environment variables
BROKERS=redpanda:9092
TOPIC=demo-work
PORT=8080
DEFAULT_WORK_UNITS=50000
DEFAULT_BURST_COUNT=1000

### Endpoints
GET /health
POST /produce

### POST /produce request
{
  "count": 100,
  "workUnits": 50000
}

### POST /produce response
{
  "status": "accepted",
  "produced": 100
}

## Consumer
### Environment variables
BROKERS=redpanda:9092
TOPIC=demo-work
GROUP_ID=demo-work-consumer-group
PORT=8080

### Endpoints
GET /health
GET /metrics

### Processing model
Each consumed message contains:
- id
- workUnits
- createdAt

Consumer simulates CPU work based on workUnits.

## KEDA
### Scale target
Deployment named: consumer

### Bootstrap server
redpanda.demo-2-redpanda-keda.svc.cluster.local:9092

### Topic
demo-work

### Consumer group
demo-work-consumer-group

### Scaling settings
minReplicaCount: 1
maxReplicaCount: 5
lagThreshold: 50
activationLagThreshold: 1
pollingInterval: 5
cooldownPeriod: 30

## Topic partitions
5

## Image names
Producer image: demo-2-producer:latest
Consumer image: demo-2-consumer:latest

## Kubernetes objects
- Namespace: demo-2-redpanda-keda
- Deployment: redpanda
- Service: redpanda
- Deployment: producer
- Service: producer
- Deployment: consumer
- ScaledObject: consumer-kafka-lag

## Important rules
- Use values from this DESIGN.md exactly.
- Do not invent alternative topic names, service names, group IDs, namespaces, or image names.
- Producer, consumer, and KEDA must all use the same topic and broker settings.
- Keep the implementation minimal and deterministic.