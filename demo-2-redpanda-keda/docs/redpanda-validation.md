# Redpanda Validation

## Apply manifests

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/redpanda-deployment.yaml
kubectl apply -f k8s/redpanda-service.yaml
```

## Check resources

```bash
kubectl get pods -n demo-2-redpanda-keda
kubectl get svc -n demo-2-redpanda-keda
```

## DNS and TCP checks from busybox (same namespace: demo-2-redpanda-keda)

```bash
kubectl run busybox-demo2 -n demo-2-redpanda-keda --rm -it --restart=Never --image=busybox:1.36 -- sh
```

```sh
nslookup redpanda
nc -vz redpanda 9092
exit
```

## DNS and TCP checks from busybox (keda namespace)

```bash
kubectl run busybox-keda -n keda --rm -it --restart=Never --image=busybox:1.36 -- sh
```

```sh
nslookup redpanda.demo-2-redpanda-keda.svc.cluster.local
nc -vz redpanda.demo-2-redpanda-keda.svc.cluster.local 9092
exit
```

## Exec into Redpanda pod

```bash
kubectl exec -n demo-2-redpanda-keda -it deploy/redpanda -- sh
```

## Create topic demo-work with 5 partitions

```sh
rpk topic create demo-work --partitions 5 --brokers redpanda:9092
```

## List topics

```sh
rpk topic list --brokers redpanda:9092
```
