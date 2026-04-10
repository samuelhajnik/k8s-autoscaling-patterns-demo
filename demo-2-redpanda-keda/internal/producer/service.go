package producer

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"

	"github.com/segmentio/kafka-go"
)

type Config struct {
	Brokers          string
	Topic            string
	Port             string
	DefaultWorkUnits int
	DefaultBurst     int
}

type Service struct {
	cfg    Config
	writer *kafka.Writer
}

type produceRequest struct {
	Count     int `json:"count"`
	WorkUnits int `json:"workUnits"`
}

type produceResponse struct {
	Status   string `json:"status"`
	Produced int    `json:"produced"`
}

type workMessage struct {
	ID        string `json:"id"`
	WorkUnits int    `json:"workUnits"`
	CreatedAt string `json:"createdAt"`
}

func LoadConfig() (Config, error) {
	cfg := Config{
		Brokers:          os.Getenv("BROKERS"),
		Topic:            os.Getenv("TOPIC"),
		Port:             os.Getenv("PORT"),
		DefaultWorkUnits: mustEnvInt("DEFAULT_WORK_UNITS"),
		DefaultBurst:     mustEnvInt("DEFAULT_BURST_COUNT"),
	}

	if cfg.Brokers == "" || cfg.Topic == "" || cfg.Port == "" {
		return Config{}, fmt.Errorf("BROKERS, TOPIC, and PORT must be set")
	}
	return cfg, nil
}

func New(cfg Config) *Service {
	writer := &kafka.Writer{
		Addr:     kafka.TCP(cfg.Brokers),
		Topic:    cfg.Topic,
		Balancer: &kafka.LeastBytes{},
	}
	return &Service{cfg: cfg, writer: writer}
}

func (s *Service) Close() error {
	return s.writer.Close()
}

func (s *Service) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /health", s.handleHealth)
	mux.HandleFunc("POST /produce", s.handleProduce)
	return mux
}

func (s *Service) handleHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Service) handleProduce(w http.ResponseWriter, r *http.Request) {
	defer r.Body.Close()

	var req produceRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid JSON body"})
		return
	}

	count := req.Count
	if count <= 0 {
		count = s.cfg.DefaultBurst
	}
	workUnits := req.WorkUnits
	if workUnits <= 0 {
		workUnits = s.cfg.DefaultWorkUnits
	}

	messages := make([]kafka.Message, 0, count)
	now := time.Now().UTC()
	for i := 0; i < count; i++ {
		payload := workMessage{
			ID:        fmt.Sprintf("%d-%d", now.UnixNano(), i),
			WorkUnits: workUnits,
			CreatedAt: now.Format(time.RFC3339Nano),
		}
		value, err := json.Marshal(payload)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "failed to encode message"})
			return
		}
		messages = append(messages, kafka.Message{
			Key:   []byte(payload.ID),
			Value: value,
		})
	}

	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()

	if err := s.writer.WriteMessages(ctx, messages...); err != nil {
		log.Printf("produce failed: topic=%s brokers=%s err=%v", s.cfg.Topic, s.cfg.Brokers, err)
		writeJSON(w, http.StatusBadGateway, map[string]string{"error": "failed to publish messages"})
		return
	}

	log.Printf("produced messages: topic=%s brokers=%s count=%d workUnits=%d", s.cfg.Topic, s.cfg.Brokers, count, workUnits)
	writeJSON(w, http.StatusAccepted, produceResponse{
		Status:   "accepted",
		Produced: count,
	})
}

func mustEnvInt(name string) int {
	val := os.Getenv(name)
	if val == "" {
		log.Fatalf("%s must be set", name)
	}
	n, err := strconv.Atoi(val)
	if err != nil {
		log.Fatalf("%s must be a valid integer: %v", name, err)
	}
	return n
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
