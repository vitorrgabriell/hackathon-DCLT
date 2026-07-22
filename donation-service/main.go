package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sqs"
	_ "github.com/jackc/pgx/v4/stdlib"
	"github.com/joho/godotenv"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/trace"
)

type Donation struct {
	ID        int       `json:"id"`
	NgoID     int       `json:"ngo_id"`
	Amount    float64   `json:"amount"`
	DonorName string    `json:"donor_name"`
	Status    string    `json:"status"`
	CreatedAt time.Time `json:"created_at"`
}

type App struct {
	DB          *sql.DB
	SqsSvc      *sqs.SQS
	SqsQueueURL string
	NgoClient   *http.Client
	NgoBaseURL  string
}

var tracer = otel.Tracer("donation-service")

func main() {
	_ = godotenv.Load()

	ctx := context.Background()
	shutdown, err := initTracer(ctx)
	if err != nil {
		log.Printf("Falha ao iniciar OpenTelemetry: %v", err)
	} else {
		defer func() {
			if err := shutdown(ctx); err != nil {
				log.Printf("Erro no shutdown do tracer: %v", err)
			}
		}()
	}

	meterShutdown, err := initMeter(ctx)
	if err != nil {
		log.Printf("Falha ao iniciar métricas OpenTelemetry: %v", err)
	} else {
		defer func() {
			if err := meterShutdown(ctx); err != nil {
				log.Printf("Erro no shutdown do meter: %v", err)
			}
		}()
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}

	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		log.Fatal("DATABASE_URL é obrigatória")
	}

	db, err := sql.Open("pgx", dbURL)
	if err != nil || db.Ping() != nil {
		log.Fatalf("Erro ao conectar ao banco de dados: %v", err)
	}
	log.Println("Conectado ao PostgreSQL (donation-service).")

	var sqsSvc *sqs.SQS
	queueURL := os.Getenv("AWS_SQS_URL")
	region := os.Getenv("AWS_REGION")
	if queueURL != "" && region != "" {
		cfg := &aws.Config{Region: aws.String(region)}
		if endpoint := os.Getenv("AWS_SQS_ENDPOINT"); endpoint != "" {
			cfg.Endpoint = aws.String(endpoint)
			cfg.DisableSSL = aws.Bool(true)
		}
		sess, _ := session.NewSession(cfg)
		sqsSvc = sqs.New(sess)
		log.Println("Integração com AWS SQS ativada.")
	}

	ngoBaseURL := os.Getenv("NGO_SERVICE_URL")
	if ngoBaseURL == "" {
		ngoBaseURL = "http://ngo-service:8081"
	}

	app := &App{
		DB:          db,
		SqsSvc:      sqsSvc,
		SqsQueueURL: queueURL,
		NgoBaseURL:  ngoBaseURL,
		NgoClient: &http.Client{
			Timeout:   3 * time.Second,
			Transport: otelhttp.NewTransport(http.DefaultTransport),
		},
	}

	// WithRouteTag marca o http.route em cada handler — é o que permite os SLIs
	// filtrarem só /donations, excluindo o ruído das probes em /health.
	// Ver docs/sre/slo-donation-service.md.
	mux := http.NewServeMux()
	mux.Handle("/health", otelhttp.WithRouteTag("/health", http.HandlerFunc(app.HealthHandler)))
	mux.Handle("/donations", otelhttp.WithRouteTag("/donations", http.HandlerFunc(app.DonationHandler)))

	handler := otelhttp.NewHandler(mux, "donation-service")

	log.Printf("donation-service rodando na porta %s", port)
	log.Fatal(http.ListenAndServe(":"+port, handler))
}

func (a *App) HealthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte(`{"status":"ok","service":"donation-service"}`))
}

func (a *App) DonationHandler(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	w.Header().Set("Content-Type", "application/json")

	if r.Method == http.MethodPost {
		var d Donation
		if err := json.NewDecoder(r.Body).Decode(&d); err != nil {
			http.Error(w, `{"error":"Payload inválido"}`, http.StatusBadRequest)
			return
		}

		exists, err := a.ngoExists(ctx, d.NgoID)
		if err != nil {
			log.Printf("Erro ao validar ngo_id %d no ngo-service: %v", d.NgoID, err)
			http.Error(w, `{"error":"Não foi possível validar a ONG informada"}`, http.StatusServiceUnavailable)
			return
		}
		if !exists {
			http.Error(w, `{"error":"ngo_id inexistente"}`, http.StatusBadRequest)
			return
		}

		d.Status = "APPROVED"

		err = func() error {
			dbCtx, span := tracer.Start(ctx, "db.insert_donation",
				trace.WithAttributes(attribute.Int("donation.ngo_id", d.NgoID)))
			defer span.End()
			_ = dbCtx

			return a.DB.QueryRow(
				"INSERT INTO donations (ngo_id, amount, donor_name, status) VALUES ($1, $2, $3, $4) RETURNING id, created_at",
				d.NgoID, d.Amount, d.DonorName, d.Status,
			).Scan(&d.ID, &d.CreatedAt)
		}()

		if err != nil {
			log.Printf("Erro ao salvar doação: %v", err)
			http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
			return
		}

		if a.SqsSvc != nil {
			a.sendNotificationEvent(ctx, d)
		}

		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(d)
		return
	}

	if r.Method == http.MethodGet {
		rows, err := a.DB.Query("SELECT id, ngo_id, amount, donor_name, status, created_at FROM donations ORDER BY id DESC")
		if err != nil {
			http.Error(w, `{"error":"Erro interno"}`, http.StatusInternalServerError)
			return
		}
		defer rows.Close()

		donations := []Donation{}
		for rows.Next() {
			var d Donation
			rows.Scan(&d.ID, &d.NgoID, &d.Amount, &d.DonorName, &d.Status, &d.CreatedAt)
			donations = append(donations, d)
		}

		json.NewEncoder(w).Encode(donations)
		return
	}

	http.Error(w, `{"error":"Método não permitido"}`, http.StatusMethodNotAllowed)
}

func (a *App) ngoExists(ctx context.Context, ngoID int) (bool, error) {
	url := fmt.Sprintf("%s/ngos/%d", a.NgoBaseURL, ngoID)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}

	resp, err := a.NgoClient.Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()

	switch resp.StatusCode {
	case http.StatusOK:
		return true, nil
	case http.StatusNotFound:
		return false, nil
	default:
		return false, fmt.Errorf("ngo-service retornou status inesperado: %d", resp.StatusCode)
	}
}

func (a *App) sendNotificationEvent(ctx context.Context, d Donation) {
	spanCtx, span := tracer.Start(ctx, "sqs.publish_donation_event")
	defer span.End()

	carrier := propagation.MapCarrier{}
	otel.GetTextMapPropagator().Inject(spanCtx, carrier)

	attrs := map[string]*sqs.MessageAttributeValue{}
	for k, v := range carrier {
		attrs[k] = &sqs.MessageAttributeValue{
			DataType:    aws.String("String"),
			StringValue: aws.String(v),
		}
	}

	body, _ := json.Marshal(d)
	_, err := a.SqsSvc.SendMessage(&sqs.SendMessageInput{
		MessageBody:       aws.String(string(body)),
		QueueUrl:          aws.String(a.SqsQueueURL),
		MessageAttributes: attrs,
	})
	if err != nil {
		log.Printf("Falha ao despachar evento SQS: %v", err)
	}
}
