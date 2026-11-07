package main

import (
	"log"
	"net/http"
	"os"

	"cicd-demo/internal/handler"
)

func main() {
	mux := http.NewServeMux()

	mux.HandleFunc("/", handler.Home)
	mux.HandleFunc("/health/live", handler.Live)
	mux.HandleFunc("/health/ready", handler.Ready)

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	server := &http.Server{
		Addr:    ":" + port,
		Handler: mux,
	}

	log.Printf("Starting server on port %s", port)

	if err := server.ListenAndServe(); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}
