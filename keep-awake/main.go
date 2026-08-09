package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"runtime/debug"
	"strings"
	"time"

	"github.com/IVIJL/boxa/keep-awake/internal/awake"
	"github.com/IVIJL/boxa/keep-awake/internal/httpapi"
	"github.com/IVIJL/boxa/keep-awake/internal/inhibit"
	"github.com/IVIJL/boxa/keep-awake/internal/netlisten"
	"github.com/IVIJL/boxa/keep-awake/internal/powerwatch"
)

var version = "dev"

type stringList []string

func (s *stringList) String() string { return strings.Join(*s, ",") }
func (s *stringList) Set(value string) error {
	*s = append(*s, value)
	return nil
}

type config struct {
	port         int
	extra        stringList
	listenUnsafe bool
	defaultTTL   time.Duration
	logFile      string
	powerCommand string
	powerTimeout time.Duration
}

func main() { os.Exit(realMain()) }

func realMain() (exitCode int) {
	cfg := config{}
	flag.IntVar(&cfg.port, "port", 17777, "HTTP listen port")
	flag.Var(&cfg.extra, "listen-address", "additional IP address (repeatable; non-loopback requires -listen-unsafe; wildcards forbidden)")
	flag.BoolVar(&cfg.listenUnsafe, "listen-unsafe", false, "WARNING: allow -listen-address to bind non-loopback interfaces, including LAN-facing ones")
	flag.DurationVar(&cfg.defaultTTL, "default-ttl", 15*time.Minute, "lease TTL when the request omits ttl")
	flag.StringVar(&cfg.logFile, "log-file", "keep-awake.log", "append-only daemon and crash log")
	flag.StringVar(&cfg.powerCommand, "power-watch-command", powerwatch.DefaultCommand, "host command run before sleep or shutdown")
	flag.DurationVar(&cfg.powerTimeout, "power-watch-timeout", time.Minute, "maximum pre-sleep stop duration")
	flag.Parse()

	logFile, err := os.OpenFile(cfg.logFile, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		fmt.Fprintf(os.Stderr, "keep-awake: open log file: %v\n", err)
		return 1
	}
	defer logFile.Close()
	logger := log.New(io.MultiWriter(os.Stderr, logFile), "keep-awake: ", log.Ldate|log.Ltime|log.LUTC)
	defer func() {
		if recovered := recover(); recovered != nil {
			logger.Printf("panic: %v\n%s", recovered, debug.Stack())
			exitCode = 1
		}
	}()

	if cfg.defaultTTL <= 0 {
		logger.Printf("default TTL must be positive")
		return 2
	}
	if strings.TrimSpace(cfg.powerCommand) == "" {
		logger.Printf("power-watch command must not be empty")
		return 2
	}
	if cfg.powerTimeout <= 0 {
		logger.Printf("power-watch timeout must be positive")
		return 2
	}
	if cfg.port < 1 || cfg.port > 65535 {
		logger.Printf("port must be between 1 and 65535")
		return 2
	}
	addresses, err := netlisten.Addresses(cfg.extra, cfg.listenUnsafe)
	if err != nil {
		logger.Printf("invalid configuration: %v", err)
		return 2
	}
	listeners, err := netlisten.Open(addresses, cfg.port, nil)
	if err != nil {
		logger.Printf("cannot bind port %d; another keep-awake instance may already be running: %v", cfg.port, err)
		return 1
	}
	defer closeListeners(listeners)

	ctx, stop := signal.NotifyContext(context.Background(), shutdownSignals()...)
	defer stop()
	if err := run(ctx, cfg, addresses, listeners, logger); err != nil {
		logger.Printf("daemon stopped with error: %v", err)
		return 1
	}
	return 0
}

func run(ctx context.Context, cfg config, addresses []string, listeners []net.Listener, logger *log.Logger) error {
	runCtx, cancelRun := context.WithCancel(ctx)
	defer cancelRun()
	registry := awake.NewRegistry(awake.RealClock{})
	manager := awake.NewManager(registry, inhibit.New())
	powerWatch := powerwatch.New(cfg.powerCommand, cfg.powerTimeout, logger.Writer(), logger)
	defer func() {
		if err := manager.Close(); err != nil {
			logger.Printf("release sleep inhibitor: %v", err)
		}
	}()

	handler := httpapi.New(manager, powerWatch.Status, cfg.defaultTTL, version, logger)
	server := &http.Server{
		Handler:           handler,
		ErrorLog:          logger,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       30 * time.Second,
	}

	managerDone := make(chan struct{})
	go func() {
		defer close(managerDone)
		manager.Run(runCtx, time.Second, func(err error) {
			logger.Printf("reconcile sleep inhibitor: %v", err)
		})
	}()
	powerWatchDone := make(chan struct{})
	go func() {
		defer close(powerWatchDone)
		if err := powerWatch.Run(runCtx); err != nil {
			logger.Printf("power-watch stopped: %v", err)
		}
	}()

	serveErrors := make(chan error, len(listeners))
	for _, listener := range listeners {
		listener := listener
		go func() {
			err := server.Serve(listener)
			if err != nil && !errors.Is(err, http.ErrServerClosed) {
				serveErrors <- err
			}
		}()
	}
	logger.Printf("version %s listening on %s (port %d)", version, strings.Join(addresses, ", "), cfg.port)

	var serveErr error
	select {
	case <-ctx.Done():
	case serveErr = <-serveErrors:
	}
	cancelRun()
	<-managerDone
	<-powerWatchDone

	shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := server.Shutdown(shutdownCtx); err != nil && serveErr == nil {
		serveErr = fmt.Errorf("HTTP shutdown: %w", err)
	}
	return serveErr
}

func closeListeners(listeners []net.Listener) {
	for _, listener := range listeners {
		_ = listener.Close()
	}
}
