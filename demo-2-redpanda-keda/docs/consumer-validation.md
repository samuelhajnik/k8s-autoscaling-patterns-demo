# Consumer Validation

## Build consumer image

```bash
docker build -f Dockerfile.consumer -t demo-2-consumer:latest .
```

## Load image into kind

```bash
kind load docker-image demo-2-consumer:latest
```

## Apply consumer manifest

```bash
kubectl apply -f k8s/consumer-deployment.yaml
kubectl get pods -n demo-2-redpanda-keda -l app=consumer
```

## Inspect consumer logs

```bash
kubectl logs -n demo-2-redpanda-keda deploy/consumer --tail=100 -f
```

## Verify producer messages are consumed

```bash
curl -sS -X POST http://localhost:8080/produce \
  -H 'Content-Type: application/json' \
  -d '{"count":10,"workUnits":50000}'
```

```bash
kubectl logs -n demo-2-redpanda-keda deploy/consumer --tail=200 | rg "processed message"
```
