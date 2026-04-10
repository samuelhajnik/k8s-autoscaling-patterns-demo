# KEDA Validation

## Apply ScaledObject

```bash
kubectl apply -f k8s/keda-scaledobject.yaml
```

## Inspect ScaledObject

```bash
kubectl get scaledobject -n demo-2-redpanda-keda
kubectl describe scaledobject consumer-kafka-lag -n demo-2-redpanda-keda
```

## Inspect HPA created by KEDA

```bash
kubectl get hpa -n demo-2-redpanda-keda
kubectl describe hpa -n demo-2-redpanda-keda
```

## Inspect KEDA operator logs

```bash
kubectl logs -n keda deploy/keda-operator --tail=200 -f
```

## Verify trigger health

```bash
kubectl get scaledobject consumer-kafka-lag -n demo-2-redpanda-keda -o yaml | rg "health|status|message|consumerGroup|topic"
```

## Watch scale-up and scale-down

```bash
kubectl get deploy consumer -n demo-2-redpanda-keda -w
```

```bash
kubectl get hpa -n demo-2-redpanda-keda -w
```
