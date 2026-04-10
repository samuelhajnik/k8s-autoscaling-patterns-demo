package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"net/http"
	"sync"
	"sync/atomic"
	"time"
)

func main() {
	target := flag.String("target", "http://localhost:8080/work", "target /work endpoint")
	total := flag.Int("total", 1000, "total number of requests")
	concurrency := flag.Int("concurrency", 20, "number of concurrent workers")
	workUnits := flag.Int("workUnits", 200000, "work units per request")
	flag.Parse()

	var success atomic.Uint64
	var failed atomic.Uint64

	start := time.Now()
	jobs := make(chan int)

	var wg sync.WaitGroup
	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()

			client := &http.Client{Timeout: 30 * time.Second}

			for range jobs {
				body, _ := json.Marshal(map[string]int{
					"workUnits": *workUnits,
				})

				resp, err := client.Post(*target, "application/json", bytes.NewReader(body))
				if err != nil {
					failed.Add(1)
					continue
				}

				_ = resp.Body.Close()

				if resp.StatusCode >= 200 && resp.StatusCode < 300 {
					success.Add(1)
				} else {
					failed.Add(1)
				}
			}
		}()
	}

	for i := 0; i < *total; i++ {
		jobs <- i
	}
	close(jobs)
	wg.Wait()

	duration := time.Since(start)
	fmt.Printf("Done in %v\n", duration)
	fmt.Printf("Success: %d\n", success.Load())
	fmt.Printf("Failed: %d\n", failed.Load())
}
