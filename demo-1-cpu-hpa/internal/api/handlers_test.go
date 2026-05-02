package api

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"demo-1-cpu-hpa/internal/config"
	"demo-1-cpu-hpa/internal/metrics"
	"demo-1-cpu-hpa/internal/model"
	"demo-1-cpu-hpa/internal/service"
)

func TestMain(m *testing.M) {
	metrics.Register()
	os.Exit(m.Run())
}

func TestHealthReturnsOK(t *testing.T) {
	h := NewHandler(config.Config{Port: "8080", DefaultWorkUnits: 1}, &service.Stats{})
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	h.Health(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status: got %d, want %d", res.StatusCode, http.StatusOK)
	}
	var body map[string]string
	if err := json.NewDecoder(res.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body["status"] != "ok" {
		t.Fatalf("status field: got %q, want ok", body["status"])
	}
}

func TestWorkUsesDefaultWorkUnitsWhenOmitted(t *testing.T) {
	cfg := config.Config{Port: "8080", DefaultWorkUnits: 1}
	stats := &service.Stats{}
	h := NewHandler(cfg, stats)

	body := bytes.NewBufferString(`{}`)
	req := httptest.NewRequest(http.MethodPost, "/work", body)
	rec := httptest.NewRecorder()

	h.Work(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status: got %d", res.StatusCode)
	}
	var got map[string]any
	if err := json.NewDecoder(res.Body).Decode(&got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if int(got["workUnits"].(float64)) != cfg.DefaultWorkUnits {
		t.Fatalf("workUnits: got %v, want %d", got["workUnits"], cfg.DefaultWorkUnits)
	}

	r, s, f := stats.Snapshot()
	if r != 1 || s != 1 || f != 0 {
		t.Fatalf("stats: received=%d succeeded=%d failed=%d, want 1,1,0", r, s, f)
	}
}

func TestWorkRejectsInvalidJSON(t *testing.T) {
	stats := &service.Stats{}
	h := NewHandler(config.Config{DefaultWorkUnits: 1}, stats)

	req := httptest.NewRequest(http.MethodPost, "/work", strings.NewReader(`not json`))
	rec := httptest.NewRecorder()

	h.Work(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusBadRequest {
		t.Fatalf("status: got %d, want %d", res.StatusCode, http.StatusBadRequest)
	}
	r, s, f := stats.Snapshot()
	if r != 1 || s != 0 || f != 1 {
		t.Fatalf("stats: received=%d succeeded=%d failed=%d, want 1,0,1", r, s, f)
	}
}

func TestWorkRejectsInvalidWorkUnits(t *testing.T) {
	stats := &service.Stats{}
	h := NewHandler(config.Config{DefaultWorkUnits: 1}, stats)

	payload := `{"workUnits":-1}`
	req := httptest.NewRequest(http.MethodPost, "/work", strings.NewReader(payload))
	rec := httptest.NewRecorder()

	h.Work(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusBadRequest {
		t.Fatalf("status: got %d, want %d", res.StatusCode, http.StatusBadRequest)
	}
	r, s, f := stats.Snapshot()
	if r != 1 || s != 0 || f != 1 {
		t.Fatalf("stats: received=%d succeeded=%d failed=%d, want 1,0,1", r, s, f)
	}
}

func TestStatsEndpointReturnsCounters(t *testing.T) {
	stats := &service.Stats{}
	stats.IncReceived()
	stats.IncSucceeded()
	stats.IncFailed()

	h := NewHandler(config.Config{}, stats)
	req := httptest.NewRequest(http.MethodGet, "/stats", nil)
	rec := httptest.NewRecorder()

	h.StatsEndpoint(rec, req)

	res := rec.Result()
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status: got %d", res.StatusCode)
	}
	var got model.StatsResponse
	if err := json.NewDecoder(res.Body).Decode(&got); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if got.RequestsReceived != 1 || got.RequestsSucceeded != 1 || got.RequestsFailed != 1 {
		t.Fatalf("response: %+v, want received=1 succeeded=1 failed=1", got)
	}
}
