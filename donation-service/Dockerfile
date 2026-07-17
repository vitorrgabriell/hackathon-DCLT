
FROM golang:1.23-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go otel.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-w -s" -o /out/donation-service .

FROM alpine:3.19 AS runtime

RUN apk add --no-cache ca-certificates && \
    addgroup -S -g 1000 app && \
    adduser -S -u 1000 -G app -H app

WORKDIR /app

COPY --from=builder /out/donation-service .

USER app

EXPOSE 8082

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -q -O- http://127.0.0.1:8082/health || exit 1

ENTRYPOINT ["./donation-service"]
