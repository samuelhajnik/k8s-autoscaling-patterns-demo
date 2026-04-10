package consumer

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"sync/atomic"
	"time"

	"github.com/segmentio/kafka-go"
)

type Config struct {
	Brokers string
	Topic   string
	GroupID string
	Port    string
}

type Service struct {
	cfg              Config
	reader           *kafka.Reader
	processedTotal   atomic.Uint64
	processingErrors atomic.Uint64
}

type workMessage struct {
	ID        string `json:"id"`
	WorkUnits int    `json:"workUnits"`
	CreatedAt string `json:"createdAt"`
}

func LoadConfig() (Config, error) {
	cfg := Config{
		Brokers: os.Getenv("BROKERS"),
		Topic:   os.Getenv("TOPIC"),
		GroupID: os.Getenv("GROUP_ID"),
		Port:    os.Getenv("PORT"),
	}
	if cfg.Brokers == "" || cfg.Topic == "" || cfg.GroupID == "" || cfg.Port == "" {
		return Config{}, fmt.Errorf("BROKERS, TOPIC, GROUP_ID, and PORT must be set")
	}
	return cfg, nil
}

func New(cfg Config) *Service {
	reader := kafka.NewReader(kafka.ReaderConfig{
		Brokers: []string{cfg.Brokers},
		Topic:   cfg.Topic,
		GroupID: cfg.GroupID,
		MinBytes: 1,
		MaxBytes: 10e6,
	})
	return &Service{
		cfg:    cfg,
		reader: reader,
	}
}

func (s *Service) Close() error {
	return s.reader.Close()
}

func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("GET /metrics", s.handleMetrics)
	return mux
}

func (s *Service) Start(ctx context.Context) {
	log.Printf("consumer starting: brokers=%s topic=%s groupID=%s", s.cfg.Brokers, s.cfg.Topic, s.cfg.GroupID)

	for {
		select {
		case <-ctx.Done():
			log.Println("consumer loop stopped")
			return
		default:
		}

		msg, err := s.reader.FetchMessage(ctx)
		if err != nil {
			if ctx.Err() != nil {
				return
			}
			s.processingErrors.Add(1)
			log.Printf("consume failed: %v", err)
			time.Sleep(500 * time.Millisecond)
			continue
		}

		if err := s.processAndCommit(ctx, msg); err != nil {
			s.processingErrors.Add(1)
			log.Printf("process failed: partition=%d offset=%d err=%v", msg.Partition, msg.Offset, err)
			continue
		}
	}
}

func (s *Service) processAndCommit(ctx context.Context, msg kafka.Message) error {
	var payload workMessage
	if err := json.Unmarshal(msg.Value, &payload); err != nil {
		return fmt.Errorf("decode message: %w", err)
	}

	if payload.WorkUnits < 0 {
		payload.WorkUnits = 0
	}
	simulateCPU(payload.WorkUnits)

	if err := s.reader.CommitMessages(ctx, msg); err != nil {
		return fmt.Errorf("commit message: %w", err)
	}

	total := s.processedTotal.Add(1)
	log.Printf(
		"processed message: id=%s workUnits=%d createdAt=%s partition=%d offset=%d total=%d",
		payload.ID, payload.WorkUnits, payload.CreatedAt, msg.Partition, msg.Offset, total,
	)
	return nil
}

func (s *Service) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Service) handleMetrics(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]uint64{
		"processedTotal":   s.processedTotal.Load(),
		"processingErrors": s.processingErrors.Load(),
	})
}

func simulateCPU(workUnits int) {
	iterations := workUnits * 200
	var acc uint64 = 1
	for i := 1; i <= iterations; i++ {
		acc = acc*1664525 + uint64(i) + 1013904223
	}
	if acc == 0 {
		log.Print(strconv.FormatUint(acc, 10))
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
