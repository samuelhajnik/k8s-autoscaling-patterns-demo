package metrics

import "github.com/prometheus/client_golang/prometheus"

var (
	RequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "demo_requests_total",
			Help: "Total HTTP requests by endpoint and status.",
		},
		[]string{"endpoint", "status"},
	)

	RequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "demo_request_duration_seconds",
			Help:    "Request duration in seconds.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"endpoint"},
	)

	WorkUnitsProcessed = prometheus.NewCounter(
		prometheus.CounterOpts{
			Name: "demo_work_units_processed_total",
			Help: "Total work units processed.",
		},
	)
)

func Register() {
	prometheus.MustRegister(RequestsTotal)
	prometheus.MustRegister(RequestDuration)
	prometheus.MustRegister(WorkUnitsProcessed)
}
