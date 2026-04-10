FROM golang:1.22 AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o server ./cmd/server

FROM gcr.io/distroless/base-debian12

WORKDIR /app
COPY --from=builder /app/server /app/server

EXPOSE 8080

ENV PORT=8080
CMD ["/app/server"]
