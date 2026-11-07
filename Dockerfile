FROM golang:1.21-alpine AS builder

WORKDIR /src

COPY go.mod ./
COPY cmd/ ./cmd/
COPY internal/ ./internal/

RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w" \
    -o /app/server ./cmd/server

# Runtime stage
FROM scratch

COPY --from=builder /app/server /server

USER 65532:65532

EXPOSE 8080

ENV PORT=8080

ENTRYPOINT ["/server"]