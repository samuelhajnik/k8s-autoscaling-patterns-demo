package producer

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/segmentio/kafka-go"
)

type fakeWriter struct {
	msgs []kafka.Message
	err  error
}

func (f *fakeWriter) WriteMessages(ctx context.Context, msgs ...kafka.Message) error {
	if f.err != nil {
		return f.err
	}
	f.msgs = append(f.msgs, msgs...)
	return nil
}

func (f *fakeWriter) Close() error {
	return nil
}

func TestLoadConfigRequiresBrokerTopicAndPort(t *testing.T) {
	t.Setenv("BROKERS", "")
	t.Setenv("TOPIC", "demo-work")
	t.Setenv("PORT", "8080")
	t.Setenv("DEFAULT_WORK_UNITS", "1")
	t.Setenv("DEFAULT_BURST_COUNT", "2")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig: expected error when BROKERS is missing")
	}

	t.Setenv("BROKERS", "localhost:9092")
	t.Setenv("TOPIC", "")
	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig: expected error when TOPIC is missing")
	}

	t.Setenv("TOPIC", "demo-work")
	t.Setenv("PORT", "")
	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig: expected error when PORT is missing")
	}
}

func TestProduceUsesDefaultsAndPublishesMessages(t *testing.T) {
	cfg := Config{
		Brokers:          "localhost:9092",
		Topic:            "demo-work",
		Port:             "8080",
		DefaultWorkUnits: 3,
		DefaultBurst:     2,
	}
	fw := &fakeWriter{}
	svc := NewWithWriter(cfg, fw)

	body := bytes.NewBufferString(`{}`)
	req := httptest.NewRequest(http.MethodPost, "/produce", body)
	rec := httptest.NewRecorder()

	svc.Handler().ServeHTTP(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusAccepted {
		b, _ := io.ReadAll(res.Body)
		t.Fatalf("status: got %d body=%s", res.StatusCode, b)
	}

	if len(fw.msgs) != cfg.DefaultBurst {
		t.Fatalf("messages written: got %d, want %d", len(fw.msgs), cfg.DefaultBurst)
	}

	for _, m := range fw.msgs {
		if len(m.Key) == 0 {
			t.Fatal("message key: expected non-empty")
		}
		var payload struct {
			ID        string `json:"id"`
			WorkUnits int    `json:"workUnits"`
			CreatedAt string `json:"createdAt"`
		}
		if err := json.Unmarshal(m.Value, &payload); err != nil {
			t.Fatalf("value JSON: %v", err)
		}
		if payload.ID == "" || payload.CreatedAt == "" {
			t.Fatalf("payload: %+v", payload)
		}
		if payload.WorkUnits != cfg.DefaultWorkUnits {
			t.Fatalf("workUnits: got %d, want %d", payload.WorkUnits, cfg.DefaultWorkUnits)
		}
	}
}

func TestProduceRejectsInvalidJSON(t *testing.T) {
	cfg := Config{DefaultBurst: 2, DefaultWorkUnits: 3}
	fw := &fakeWriter{}
	svc := NewWithWriter(cfg, fw)

	req := httptest.NewRequest(http.MethodPost, "/produce", strings.NewReader(`not-json`))
	rec := httptest.NewRecorder()

	svc.Handler().ServeHTTP(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusBadRequest {
		t.Fatalf("status: got %d, want %d", res.StatusCode, http.StatusBadRequest)
	}
	if len(fw.msgs) != 0 {
		t.Fatalf("expected no messages, got %d", len(fw.msgs))
	}
}

func TestProduceReturnsBadGatewayWhenPublishFails(t *testing.T) {
	cfg := Config{DefaultBurst: 2, DefaultWorkUnits: 3}
	fw := &fakeWriter{err: errors.New("broker unavailable")}
	svc := NewWithWriter(cfg, fw)

	req := httptest.NewRequest(http.MethodPost, "/produce", strings.NewReader(`{}`))
	rec := httptest.NewRecorder()

	svc.Handler().ServeHTTP(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusBadGateway {
		t.Fatalf("status: got %d, want %d", res.StatusCode, http.StatusBadGateway)
	}
}

func TestHealthReturnsOK(t *testing.T) {
	cfg := Config{}
	fw := &fakeWriter{}
	svc := NewWithWriter(cfg, fw)

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	svc.Handler().ServeHTTP(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status: got %d", res.StatusCode)
	}
}
