package service

import "sync/atomic"

type Stats struct {
	requestsReceived  atomic.Uint64
	requestsSucceeded atomic.Uint64
	requestsFailed    atomic.Uint64
}

func (s *Stats) IncReceived() {
	s.requestsReceived.Add(1)
}

func (s *Stats) IncSucceeded() {
	s.requestsSucceeded.Add(1)
}

func (s *Stats) IncFailed() {
	s.requestsFailed.Add(1)
}

func (s *Stats) Snapshot() (received, succeeded, failed uint64) {
	return s.requestsReceived.Load(), s.requestsSucceeded.Load(), s.requestsFailed.Load()
}
