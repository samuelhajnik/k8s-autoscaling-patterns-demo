package service

import (
	"crypto/sha256"
	"fmt"
)

func Process(workUnits int) error {
	if workUnits <= 0 {
		return fmt.Errorf("workUnits must be > 0")
	}

	data := []byte("demo-cpu-work")
	hash := data

	for i := 0; i < workUnits; i++ {
		sum := sha256.Sum256(hash)
		hash = sum[:]
	}

	return nil
}
