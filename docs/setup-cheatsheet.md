# Setup Cheatsheet

For a single end-to-end local run (recommended for reviewers), use `./scripts/run-autoscaling-demo.sh` from the repo root.

The command blocks below are a condensed manual setup (they intentionally `cd` into each demo directory before `docker build` and `kubectl apply`). For prerequisites, narrative, and variations, use the per-demo READMEs:

- [Demo 1: CPU-based HPA](../demo-1-cpu-hpa/README.md)
- [Demo 2: Kafka lag-based KEDA autoscaling](../demo-2-redpanda-keda/README.md)

## Demo 1 Commands

```bash
# from repo root
kind create cluster --name k8s-autoscaling-demo

# metrics-server (required for HPA CPU metrics)
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl wait --for=condition=Available deployment/metrics-server -n kube-system --timeout=180s

# build + load image
cd demo-1-cpu-hpa
docker build -t demo-1-cpu-hpa:latest .
kind load docker-image demo-1-cpu-hpa:latest --name k8s-autoscaling-demo

# deploy
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/hpa.yaml

# port-forward + load
kubectl port-forward svc/demo-1-cpu-hpa 8080:80
# in another terminal:
go run ./cmd/loadgen --target http://localhost:8080/work --total 3000 --concurrency 50 --workUnits 300000
```

## Demo 2 Commands

```bash
# from repo root, install KEDA (requires Helm)
helm repo add kedacore https://kedacore.github.io/charts
helm repo update
helm install keda kedacore/keda --namespace keda --create-namespace
kubectl wait --for=condition=Available deployment/keda-operator -n keda --timeout=180s

# build + load images
cd demo-2-redpanda-keda
docker build -f Dockerfile.producer -t demo-2-producer:latest .
docker build -f Dockerfile.consumer -t demo-2-consumer:latest .
kind load docker-image demo-2-producer:latest --name k8s-autoscaling-demo
kind load docker-image demo-2-consumer:latest --name k8s-autoscaling-demo

# deploy
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/redpanda-deployment.yaml
kubectl apply -f k8s/redpanda-service.yaml
kubectl apply -f k8s/producer-deployment.yaml
kubectl apply -f k8s/producer-service.yaml
kubectl apply -f k8s/consumer-deployment.yaml

# create topic + apply KEDA
kubectl exec -n demo-2-redpanda-keda -it deploy/redpanda -- sh -c "rpk topic create demo-work --partitions 5 --brokers redpanda:9092"
kubectl apply -f k8s/keda-scaledobject.yaml

# port-forward producer + generate load
kubectl port-forward -n demo-2-redpanda-keda svc/producer 8080:8080
# in another terminal:
go run ./cmd/loadgen -target http://localhost:8080 -batches 20 -count 100 -workUnits 50000
```

## Useful Debugging Commands

```bash
# pods/services
kubectl get pods -A
kubectl get svc -A

# Demo 1 HPA
kubectl get hpa
kubectl describe hpa

# Demo 2 KEDA + HPA
kubectl get scaledobject -n demo-2-redpanda-keda
kubectl describe scaledobject consumer-kafka-lag -n demo-2-redpanda-keda
kubectl get hpa -n demo-2-redpanda-keda
kubectl logs -n keda deploy/keda-operator --tail=200

# app logs
kubectl logs deploy/demo-1-cpu-hpa --tail=100
kubectl logs -n demo-2-redpanda-keda deploy/producer --tail=100
kubectl logs -n demo-2-redpanda-keda deploy/consumer --tail=100
```
