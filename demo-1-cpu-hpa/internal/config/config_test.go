package config

import "testing"

func TestLoadUsesDefaults(t *testing.T) {
	t.Setenv("PORT", "")
	t.Setenv("DEFAULT_WORK_UNITS", "")

	cfg := Load()
	if cfg.Port != "8080" {
		t.Errorf("Port: got %q, want 8080", cfg.Port)
	}
	if cfg.DefaultWorkUnits != 200000 {
		t.Errorf("DefaultWorkUnits: got %d, want 200000", cfg.DefaultWorkUnits)
	}
}

func TestLoadReadsEnvironment(t *testing.T) {
	t.Setenv("PORT", "9090")
	t.Setenv("DEFAULT_WORK_UNITS", "42")

	cfg := Load()
	if cfg.Port != "9090" {
		t.Errorf("Port: got %q, want 9090", cfg.Port)
	}
	if cfg.DefaultWorkUnits != 42 {
		t.Errorf("DefaultWorkUnits: got %d, want 42", cfg.DefaultWorkUnits)
	}
}

func TestLoadFallsBackForInvalidDefaultWorkUnits(t *testing.T) {
	t.Setenv("DEFAULT_WORK_UNITS", "not-a-number")

	cfg := Load()
	if cfg.DefaultWorkUnits != 200000 {
		t.Errorf("DefaultWorkUnits: got %d, want fallback 200000", cfg.DefaultWorkUnits)
	}
}
