APP_NAME=demo-1-cpu-hpa
IMAGE_NAME=demo-1-cpu-hpa:latest

run:
	go run ./cmd/server

load:
	go run ./cmd/loadgen --target http://localhost:8080/work --total 500 --concurrency 20 --workUnits 200000

build:
	go build ./cmd/server

docker-build:
	docker build -t $(IMAGE_NAME) .

k8s-apply:
	kubectl apply -f k8s/deployment.yaml
	kubectl apply -f k8s/service.yaml
	kubectl apply -f k8s/hpa.yaml

k8s-delete:
	kubectl delete -f k8s/hpa.yaml --ignore-not-found
	kubectl delete -f k8s/service.yaml --ignore-not-found
	kubectl delete -f k8s/deployment.yaml --ignore-not-found
