package service

import "testing"

func TestStatsSnapshotTracksCounters(t *testing.T) {
	var s Stats
	r, ok, f := s.Snapshot()
	if r != 0 || ok != 0 || f != 0 {
		t.Fatalf("new Stats: got received=%d succeeded=%d failed=%d, want zeros", r, ok, f)
	}

	s.IncReceived()
	s.IncSucceeded()
	s.IncFailed()
	s.IncReceived()
	s.IncFailed()

	r, ok, f = s.Snapshot()
	if r != 2 || ok != 1 || f != 2 {
		t.Fatalf("after increments: got received=%d succeeded=%d failed=%d, want 2,1,2", r, ok, f)
	}
}
