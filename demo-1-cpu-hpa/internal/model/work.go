package model

type WorkRequest struct {
	WorkUnits int `json:"workUnits"`
}

type StatsResponse struct {
	RequestsReceived  uint64 `json:"requestsReceived"`
	RequestsSucceeded uint64 `json:"requestsSucceeded"`
	RequestsFailed    uint64 `json:"requestsFailed"`
}
