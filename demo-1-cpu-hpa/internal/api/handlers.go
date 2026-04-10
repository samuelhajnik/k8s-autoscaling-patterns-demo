package api

import (
	"encoding/json"
	"net/http"
	"time"

	"demo-1-cpu-hpa/internal/config"
	"demo-1-cpu-hpa/internal/metrics"
	"demo-1-cpu-hpa/internal/model"
	"demo-1-cpu-hpa/internal/service"
)

type Handler struct {
	Config config.Config
	Stats  *service.Stats
}

func NewHandler(cfg config.Config, stats *service.Stats) *Handler {
	return &Handler{
		Config: cfg,
		Stats:  stats,
	}
}

func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (h *Handler) StatsEndpoint(w http.ResponseWriter, r *http.Request) {
	received, succeeded, failed := h.Stats.Snapshot()

	writeJSON(w, http.StatusOK, model.StatsResponse{
		RequestsReceived:  received,
		RequestsSucceeded: succeeded,
		RequestsFailed:    failed,
	})
}

func (h *Handler) Work(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	h.Stats.IncReceived()

	var req model.WorkRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		h.Stats.IncFailed()
		metrics.RequestsTotal.WithLabelValues("/work", "bad_request").Inc()
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.WorkUnits == 0 {
		req.WorkUnits = h.Config.DefaultWorkUnits
	}

	err := service.Process(req.WorkUnits)
	if err != nil {
		h.Stats.IncFailed()
		metrics.RequestsTotal.WithLabelValues("/work", "error").Inc()
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	h.Stats.IncSucceeded()
	metrics.RequestsTotal.WithLabelValues("/work", "success").Inc()
	metrics.RequestDuration.WithLabelValues("/work").Observe(time.Since(start).Seconds())
	metrics.WorkUnitsProcessed.Add(float64(req.WorkUnits))

	writeJSON(w, http.StatusOK, map[string]any{
		"status":    "done",
		"workUnits": req.WorkUnits,
	})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
