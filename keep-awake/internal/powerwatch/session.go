package powerwatch

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	shutdownHookMaxTimeout = 10 * time.Second
	suspendQueryTimeout    = 1500 * time.Millisecond
	resumeHookTimeout      = 10 * time.Second
)

type sessionEvent uint8

const (
	sessionShutdownQuery sessionEvent = iota
	sessionShutdownEnd
	sessionShutdownCancelled
	sessionSuspend
	sessionResume
)

type sessionEventSource interface {
	Run(context.Context, func(sessionEvent)) error
	CreateShutdownBlockReason() error
	DestroyShutdownBlockReason() error
}

type boxSessionHooks interface {
	RunningBoxes(context.Context, time.Duration) ([]string, error)
	NotifySlept(context.Context, []string, time.Duration) error
}

type suspendState struct {
	SuspendedAt  time.Time `json:"suspended_at"`
	Boxes        []string  `json:"boxes"`
	StopInFlight bool      `json:"stop_in_flight,omitempty"`
}

type suspendStateStore interface {
	Save(suspendState) error
	Load() (suspendState, error)
	Clear(suspendState) error
}

type fileSuspendStateStore struct {
	path string
	mu   sync.Mutex
}

func (s *fileSuspendStateStore) Save(state suspendState) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(s.path), ".suspend-*.tmp")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	// os.Rename cannot replace an existing file on Windows. The old state is
	// safe to remove because Save holds the store lock until it is replaced.
	if err := os.Remove(s.path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return os.Rename(temporaryPath, s.path)
}

func (s *fileSuspendStateStore) Load() (suspendState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.load()
}

func (s *fileSuspendStateStore) load() (suspendState, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		return suspendState{}, err
	}
	var state suspendState
	if err := json.Unmarshal(data, &state); err != nil {
		return suspendState{}, err
	}
	return state, nil
}

func (s *fileSuspendStateStore) Clear(expected suspendState) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	current, err := s.load()
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if !current.SuspendedAt.Equal(expected.SuspendedAt) {
		return nil
	}
	err = os.Remove(s.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

type sessionWatch struct {
	source       sessionEventSource
	hooks        boxSessionHooks
	state        suspendStateStore
	runner       hookRunner
	coordination *hookCoordinator
	hookTimeout  time.Duration
	logger       *log.Logger
	now          func() time.Time

	shutdownMu       sync.Mutex
	shutdownHandled  bool
	resumeMu         sync.Mutex
	resumeInProgress bool
	resumeHooks      sync.WaitGroup
}

func newSessionWatch(source sessionEventSource, hooks boxSessionHooks, state suspendStateStore, runner hookRunner, hookTimeout time.Duration, logger *log.Logger) *sessionWatch {
	return &sessionWatch{
		source:      source,
		hooks:       hooks,
		state:       state,
		runner:      runner,
		hookTimeout: hookTimeout,
		logger:      logger,
		now:         time.Now,
	}
}

func (w *sessionWatch) Run(ctx context.Context) error {
	err := w.source.Run(ctx, func(event sessionEvent) {
		w.handle(ctx, event)
	})
	w.resumeHooks.Wait()
	return err
}

func (w *sessionWatch) handle(ctx context.Context, event sessionEvent) {
	switch event {
	case sessionShutdownQuery, sessionShutdownEnd:
		w.handleShutdown(ctx)
	case sessionShutdownCancelled:
		w.shutdownMu.Lock()
		w.shutdownHandled = false
		w.shutdownMu.Unlock()
	case sessionSuspend:
		w.handleSuspend(ctx)
	case sessionResume:
		w.handleResume(ctx)
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
	w.logf("power-watch received Windows shutdown; running pre-sleep stop with %s budget", budget)

	hookCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	started := make(chan struct{})
	result := make(chan error, 1)
	go func() {
		close(started)
		result <- w.runner.Run(hookCtx, budget)
	}()
	<-started

	timer := time.NewTimer(budget)
	defer timer.Stop()
	select {
	case err := <-result:
		if err != nil {
			w.logf("power-watch pre-sleep stop: %v", err)
		}
	case <-timer.C:
		cancel()
		w.logf("power-watch pre-sleep stop timed out after %s", budget)
	case <-ctx.Done():
		cancel()
	}
}

func (w *sessionWatch) handleSuspend(ctx context.Context) {
	if w.coordination != nil {
		if !w.coordination.TryAcquire() {
			state := suspendState{SuspendedAt: w.now().UTC(), StopInFlight: true}
			if err := w.state.Save(state); err != nil {
				w.logf("persist suspend state: %v", err)
			}
			return
		}
		w.coordination.release()
	}
	boxes, err := w.hooks.RunningBoxes(ctx, suspendQueryTimeout)
	if err != nil {
		w.logf("query running boxes at suspend: %v", err)
		return
	}
	state := suspendState{SuspendedAt: w.now().UTC(), Boxes: boxes}
	if err := w.state.Save(state); err != nil {
		w.logf("persist suspend state: %v", err)
	}
}

func (w *sessionWatch) handleResume(ctx context.Context) {
	w.resumeMu.Lock()
	if w.resumeInProgress {
		w.resumeMu.Unlock()
		return
	}
	state, err := w.state.Load()
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		w.logf("read suspend state: %v", err)
	}
	if err != nil {
		w.resumeMu.Unlock()
		return
	}
	if state.StopInFlight {
		w.resumeInProgress = true
		w.resumeHooks.Add(1)
		w.resumeMu.Unlock()
		go func() {
			defer w.resumeHooks.Done()
			defer func() {
				w.resumeMu.Lock()
				w.resumeInProgress = false
				w.resumeMu.Unlock()
			}()
			boxes, queryErr := w.hooks.RunningBoxes(ctx, resumeHookTimeout)
			if queryErr != nil {
				w.logf("query running boxes at resume: %v", queryErr)
				return
			}
			if len(boxes) > 0 {
				if notifyErr := w.hooks.NotifySlept(ctx, boxes, resumeHookTimeout); notifyErr != nil {
					w.logf("raise slept-with-boxes notification: %v", notifyErr)
					return
				}
			}
			if clearErr := w.state.Clear(state); clearErr != nil {
				w.logf("clear suspend state: %v", clearErr)
			}
		}()
		return
	}
	if len(state.Boxes) == 0 {
		if clearErr := w.state.Clear(state); clearErr != nil {
			w.logf("clear suspend state: %v", clearErr)
		}
		w.resumeMu.Unlock()
		return
	}

	boxes := append([]string(nil), state.Boxes...)
	w.resumeInProgress = true
	w.resumeHooks.Add(1)
	w.resumeMu.Unlock()
	go func() {
		defer w.resumeHooks.Done()
		defer func() {
			w.resumeMu.Lock()
			w.resumeInProgress = false
			w.resumeMu.Unlock()
		}()
		if err := w.hooks.NotifySlept(ctx, boxes, resumeHookTimeout); err != nil {
			w.logf("raise slept-with-boxes notification: %v", err)
			return
		}
		if err := w.state.Clear(state); err != nil {
			w.logf("clear suspend state: %v", err)
		}
	}()
}

func (w *sessionWatch) logf(format string, args ...any) {
	if w.logger != nil {
		w.logger.Printf(format, args...)
	}
}

func newFileSuspendStateStore(path string) (suspendStateStore, error) {
	if path == "" {
		return nil, fmt.Errorf("suspend state path is empty")
	}
	return &fileSuspendStateStore{path: path}, nil
}
