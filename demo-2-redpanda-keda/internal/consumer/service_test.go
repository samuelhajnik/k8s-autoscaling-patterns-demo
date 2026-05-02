package consumer

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLoadConfigRequiresBrokerTopicGroupAndPort(t *testing.T) {
	t.Setenv("BROKERS", "")
	t.Setenv("TOPIC", "demo-work")
	t.Setenv("GROUP_ID", "g")
	t.Setenv("PORT", "8080")

	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig: expected error when BROKERS is missing")
	}

	t.Setenv("BROKERS", "localhost:9092")
	t.Setenv("TOPIC", "")
	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig: expected error when TOPIC is missing")
	}

	t.Setenv("TOPIC", "demo-work")
	t.Setenv("GROUP_ID", "")
	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig: expected error when GROUP_ID is missing")
	}

	t.Setenv("GROUP_ID", "g")
	t.Setenv("PORT", "")
	if _, err := LoadConfig(); err == nil {
		t.Fatal("LoadConfig: expected error when PORT is missing")
	}
}

func TestHealthReturnsOK(t *testing.T) {
	s := &Service{}

	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	s.Handler().ServeHTTP(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status: got %d", res.StatusCode)
	}
}

func TestMetricsReturnsCounters(t *testing.T) {
	s := &Service{}
	s.processedTotal.Store(3)
	s.processingErrors.Store(2)

	req := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	rec := httptest.NewRecorder()

	s.Handler().ServeHTTP(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status: got %d", res.StatusCode)
	}
	body, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	var got map[string]uint64
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got["processedTotal"] != 3 || got["processingErrors"] != 2 {
		t.Fatalf("response: %+v, want processedTotal=3 processingErrors=2", got)
	}
}
