# Producer Validation

## Build producer image

```bash
docker build -f Dockerfile.producer -t demo-2-producer:latest .
```

## Load image into kind

```bash
kind load docker-image demo-2-producer:latest
```

## Apply producer manifests

```bash
kubectl apply -f k8s/producer-deployment.yaml
kubectl apply -f k8s/producer-service.yaml
kubectl get pods -n demo-2-redpanda-keda -l app=producer
kubectl get svc -n demo-2-redpanda-keda producer
```

## Port-forward producer service

```bash
kubectl port-forward -n demo-2-redpanda-keda svc/producer 8080:8080
```

## Call GET /health

```bash
curl -sS http://localhost:8080/health
```

## Call POST /produce (small test batch)

```bash
curl -sS -X POST http://localhost:8080/produce \
  -H 'Content-Type: application/json' \
  -d '{"count":10,"workUnits":50000}'
```

## Inspect producer logs

```bash
kubectl logs -n demo-2-redpanda-keda deploy/producer --tail=100 -f
```
