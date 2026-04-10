package main

import (
	"log"
	"net/http"

	"demo-1-cpu-hpa/internal/api"
	"demo-1-cpu-hpa/internal/config"
	"demo-1-cpu-hpa/internal/metrics"
	"demo-1-cpu-hpa/internal/service"

	"github.com/prometheus/client_golang/prometheus/promhttp"
)

func main() {
	cfg := config.Load()
	stats := &service.Stats{}
	metrics.Register()

	handler := api.NewHandler(cfg, stats)

	mux := http.NewServeMux()
	mux.HandleFunc("/health", handler.Health)
	mux.HandleFunc("/work", handler.Work)
	mux.HandleFunc("/stats", handler.StatsEndpoint)
	mux.Handle("/metrics", promhttp.Handler())

	addr := ":" + cfg.Port
	log.Printf("Starting server on %s", addr)

	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}
