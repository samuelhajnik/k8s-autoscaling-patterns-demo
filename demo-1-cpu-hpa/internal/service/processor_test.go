package service

import "testing"

func TestProcessRejectsNonPositiveWorkUnits(t *testing.T) {
	if err := Process(0); err == nil {
		t.Fatal("Process(0): expected error")
	}
	if err := Process(-1); err == nil {
		t.Fatal("Process(-1): expected error")
	}
	if err := Process(1); err != nil {
		t.Fatalf("Process(1): %v", err)
	}
}
