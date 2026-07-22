package main

import (
	"context"
	"log"
	"net/http"
	"os"
	"time"

	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/propagation"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

// withRouteTag substitui o otelhttp.WithRouteTag, removido a partir da v0.69 do
// otelhttp. Injeta o atributo http.route nas métricas via Labeler (o handler do
// otelhttp repassa labeler.Get() como AdditionalAttributes), preservando o label
// http_route de que os SLIs dependem pra filtrar só /donations e descartar o
// ruído das probes em /health. Ver docs/sre/slo-donation-service.md.
func withRouteTag(route string, h http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		labeler, _ := otelhttp.LabelerFromContext(r.Context())
		labeler.Add(semconv.HTTPRoute(route))
		h.ServeHTTP(w, r)
	})
}

func newResource(ctx context.Context) (*resource.Resource, error) {
	serviceName := os.Getenv("OTEL_SERVICE_NAME")
	if serviceName == "" {
		serviceName = "donation-service"
	}

	return resource.New(ctx,
		resource.WithFromEnv(),
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceNamespace("solidarytech"),
			semconv.DeploymentEnvironment("production"),
		),
	)
}

func initTracer(ctx context.Context) (func(context.Context) error, error) {
	exporter, err := otlptracehttp.New(ctx)
	if err != nil {
		return nil, err
	}

	res, err := newResource(ctx)
	if err != nil {
		return nil, err
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)

	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	log.Println("OpenTelemetry tracer initialized")
	return tp.Shutdown, nil
}

// initMeter exporta as métricas HTTP do otelhttp (http.server.duration) via OTLP
// pro Collector, que as expõe pro Prometheus. Os buckets do histograma são
// redefinidos via View pra incluir a fronteira de 300ms — o threshold do SLO de
// latência — assim o SLI de latência é calculado por contagem exata de bucket
// (le="300"), sem interpolação do histogram_quantile.
func initMeter(ctx context.Context) (func(context.Context) error, error) {
	exporter, err := otlpmetrichttp.New(ctx)
	if err != nil {
		return nil, err
	}

	res, err := newResource(ctx)
	if err != nil {
		return nil, err
	}

	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter,
			sdkmetric.WithInterval(15*time.Second))),
		sdkmetric.WithView(sdkmetric.NewView(
			sdkmetric.Instrument{Name: "http.server.duration"},
			sdkmetric.Stream{Aggregation: sdkmetric.AggregationExplicitBucketHistogram{
				Boundaries: []float64{5, 10, 25, 50, 75, 100, 150, 200, 250, 300, 400, 500, 750, 1000, 2500, 5000, 10000},
			}},
		)),
	)

	otel.SetMeterProvider(mp)
	log.Println("OpenTelemetry meter provider initialized (http.server.duration com bucket de 300ms)")
	return mp.Shutdown, nil
}
