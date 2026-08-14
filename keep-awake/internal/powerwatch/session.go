package powerwatch

import (
	"context"
	"log"
	"sync"
	"time"
)

const shutdownHookMaxTimeout = 45 * time.Second

type sessionEvent uint8

const (
	sessionShutdownQuery sessionEvent = iota
	sessionShutdownEnd
	sessionShutdownCancelled
)

type sessionEventSource interface {
	Run(context.Context, func(sessionEvent)) error
	CreateShutdownBlockReason() error
	DestroyShutdownBlockReason() error
}

type sessionWatch struct {
	source      sessionEventSource
	runner      hookRunner
	hookTimeout time.Duration
	logger      *log.Logger

	shutdownMu      sync.Mutex
	shutdownHandled bool
}

func newSessionWatch(source sessionEventSource, runner hookRunner, hookTimeout time.Duration, logger *log.Logger) *sessionWatch {
	return &sessionWatch{
		source:      source,
		runner:      runner,
		hookTimeout: hookTimeout,
		logger:      logger,
	}
}

func (w *sessionWatch) Run(ctx context.Context) error {
	return w.source.Run(ctx, func(event sessionEvent) {
		w.handle(ctx, event)
	})
}

func (w *sessionWatch) handle(ctx context.Context, event sessionEvent) {
	switch event {
	case sessionShutdownQuery, sessionShutdownEnd:
		w.handleShutdown(ctx)
	case sessionShutdownCancelled:
		w.shutdownMu.Lock()
		w.shutdownHandled = false
		w.shutdownMu.Unlock()
	}
}

func (w *sessionWatch) handleShutdown(ctx context.Context) {
	w.shutdownMu.Lock()
	if w.shutdownHandled {
		w.shutdownMu.Unlock()
		return
	}
	w.shutdownHandled = true
	w.shutdownMu.Unlock()

	blocked := false
	if err := w.source.CreateShutdownBlockReason(); err != nil {
		w.logf("create shutdown block reason: %v", err)
	} else {
		blocked = true
	}
	if blocked {
		defer func() {
			if err := w.source.DestroyShutdownBlockReason(); err != nil {
				w.logf("destroy shutdown block reason: %v", err)
			}
		}()
	}

	budget := w.hookTimeout
	if budget > shutdownHookMaxTimeout {
		budget = shutdownHookMaxTimeout
	}
	w.logf("power-watch received Windows shutdown; running pre-shutdown stop with %s budget", budget)

	hookCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	result := make(chan error, 1)
	go func() {
		result <- w.runner.Run(hookCtx, budget)
	}()

	timer := time.NewTimer(budget)
	defer timer.Stop()
	select {
	case err := <-result:
		if err != nil {
			w.logf("power-watch pre-shutdown stop: %v", err)
		}
	case <-timer.C:
		cancel()
		w.logf("power-watch pre-shutdown stop timed out after %s", budget)
	case <-ctx.Done():
		cancel()
	}
}

func (w *sessionWatch) logf(format string, args ...any) {
	if w.logger != nil {
		w.logger.Printf(format, args...)
	}
}
