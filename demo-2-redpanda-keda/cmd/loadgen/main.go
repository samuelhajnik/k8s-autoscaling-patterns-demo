package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

type produceRequest struct {
	Count     int `json:"count"`
	WorkUnits int `json:"workUnits"`
}

func main() {
	target := flag.String("target", "http://localhost:8080", "Producer base URL")
	batches := flag.Int("batches", 10, "Number of POST requests to send")
	count := flag.Int("count", 100, "Messages per batch")
	workUnits := flag.Int("workUnits", 50000, "workUnits per message")
	timeout := flag.Duration("timeout", 10*time.Second, "HTTP request timeout")
	flag.Parse()

	base := strings.TrimRight(*target, "/")
	url := base + "/produce"

	client := &http.Client{Timeout: *timeout}
	reqBody := produceRequest{Count: *count, WorkUnits: *workUnits}
	bodyBytes, _ := json.Marshal(reqBody)

	start := time.Now()
	ok := 0
	failed := 0

	for i := 1; i <= *batches; i++ {
		req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(bodyBytes))
		if err != nil {
			failed++
			fmt.Printf("batch %d failed: %v\n", i, err)
			continue
		}
		req.Header.Set("Content-Type", "application/json")

		resp, err := client.Do(req)
		if err != nil {
			failed++
			fmt.Printf("batch %d failed: %v\n", i, err)
			continue
		}

		_, _ = io.Copy(io.Discard, resp.Body)
		_ = resp.Body.Close()

		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			ok++
			fmt.Printf("batch %d/%d ok (%d)\n", i, *batches, resp.StatusCode)
		} else {
			failed++
			fmt.Printf("batch %d/%d failed (%d)\n", i, *batches, resp.StatusCode)
		}
	}

	totalMessages := (*batches) * (*count)
	elapsed := time.Since(start)
	fmt.Println("---- summary ----")
	fmt.Printf("target: %s\n", url)
	fmt.Printf("batches: %d, countPerBatch: %d, workUnits: %d\n", *batches, *count, *workUnits)
	fmt.Printf("requests ok: %d, failed: %d\n", ok, failed)
	fmt.Printf("attempted messages: %d\n", totalMessages)
	fmt.Printf("elapsed: %s\n", elapsed.Round(time.Millisecond))
}
