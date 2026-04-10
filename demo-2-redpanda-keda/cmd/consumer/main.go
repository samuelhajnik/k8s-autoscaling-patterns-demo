package main

import (
	"context"
	"log"
	"net/http"
	"os/signal"
	"syscall"
	"time"

	"demo-2-redpanda-keda/internal/consumer"
)

func main() {
	cfg, err := consumer.LoadConfig()
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	svc := consumer.New(cfg)
	defer func() {
		if err := svc.Close(); err != nil {
			log.Printf("reader close error: %v", err)
		}
	}()

	server := &http.Server{
		Addr:              ":" + cfg.Port,
		Handler:           svc.Handler(),
		ReadHeaderTimeout: 5 * time.Second,
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	go svc.Start(ctx)

	go func() {
		log.Printf("consumer metrics server listening on :%s", cfg.Port)
		if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	<-ctx.Done()
	log.Println("shutdown signal received")

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil {
		log.Printf("graceful shutdown error: %v", err)
	}
}
