package powerwatch

import (
	"context"
	"fmt"
	"io"
	"log"
	"sync"
	"time"
)

const DefaultCommand = "boxa stop --all --reason presleep"

type Event uint8

const (
	PrepareForShutdown Event = iota
	shutdownCancelled
)

type Status struct {
	Active               bool
	StopBudget           time.Duration
	InhibitDelayMax      time.Duration
	InhibitDelayMaxError string
	Hint                 string
}

type delayLock interface {
	Release() error
}

type eventSource interface {
	Subscribe(context.Context) (<-chan Event, error)
	Acquire(context.Context) (delayLock, error)
	InhibitDelayMax(context.Context) (time.Duration, error)
	Close() error
}

type hookRunner interface {
	Run(context.Context, time.Duration) error
}

type commandRunner struct {
	command string
	output  io.Writer
}

func (r commandRunner) Run(ctx context.Context, timeout time.Duration) error {
	hookCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd, err := newCommand(hookCtx, r.command)
	if err != nil {
		return err
	}
	configureCommand(cmd)
	cmd.Stdout = r.output
	cmd.Stderr = r.output
	if err := cmd.Run(); err != nil {
		if hookCtx.Err() != nil {
			return fmt.Errorf("hook timed out after %s: %w", timeout, hookCtx.Err())
		}
		return fmt.Errorf("hook failed: %w", err)
	}
	return nil
}

type Watch struct {
	mu      sync.Mutex
	source  eventSource
	runner  hookRunner
	timeout time.Duration
	logger  *log.Logger
	status  Status
	session *sessionWatch
}

func New(command string, timeout time.Duration, output io.Writer, logger *log.Logger) *Watch {
	runner := commandRunner{command: command, output: output}
	watch := newWatch(newPlatformSource(), runner, timeout, logger)
	watch.session = newPlatformSessionWatch(runner, timeout, logger)
	return watch
}

func newWatch(source eventSource, runner hookRunner, timeout time.Duration, logger *log.Logger) *Watch {
	return &Watch{
		source:  source,
		runner:  runner,
		timeout: timeout,
		logger:  logger,
		status:  Status{StopBudget: timeout},
	}
}

func (w *Watch) Run(ctx context.Context) error {
	if w.session != nil {
		w.setActive(true)
		defer w.setActive(false)
		return w.session.Run(ctx)
	}
	if w.source == nil {
		<-ctx.Done()
		return nil
	}
	defer func() {
		w.setActive(false)
		if err := w.source.Close(); err != nil && w.logger != nil {
			w.logger.Printf("close power-watch event source: %v", err)
		}
	}()

	events, err := w.source.Subscribe(ctx)
	if err != nil {
		return fmt.Errorf("subscribe to power events: %w", err)
	}
	delayMax, delayErr := w.source.InhibitDelayMax(ctx)
	w.setDelayMax(delayMax, delayErr)
	if delayErr != nil && w.logger != nil {
		w.logger.Printf("read logind InhibitDelayMaxSec: %v", delayErr)
	}

	lock, err := w.source.Acquire(ctx)
	if err != nil {
		return fmt.Errorf("acquire power-watch delay inhibitor: %w", err)
	}
	w.setActive(true)
	if w.logger != nil {
		w.logger.Printf("power-watch active (stop budget %s, logind delay %s)", w.timeout, delayDescription(delayMax, delayErr))
	}

	for {
		select {
		case <-ctx.Done():
			if lock != nil {
				if err := lock.Release(); err != nil {
					return fmt.Errorf("release power-watch delay inhibitor: %w", err)
				}
			}
			return nil
		case event, ok := <-events:
			if !ok {
				if ctx.Err() != nil {
					return nil
				}
				return fmt.Errorf("power event subscription closed")
			}
			if event == shutdownCancelled {
				if lock != nil {
					continue
				}
				lock, err = w.source.Acquire(ctx)
				if err != nil {
					return fmt.Errorf("reacquire power-watch delay inhibitor: %w", err)
				}
				w.setActive(true)
				continue
			}
			if lock == nil {
				continue
			}
			w.runHook(ctx, event, delayMax)
			if err := lock.Release(); err != nil {
				return fmt.Errorf("release power-watch delay inhibitor: %w", err)
			}
			lock = nil
			w.setActive(false)
		}
	}
}

func (w *Watch) runHook(ctx context.Context, event Event, delayMax time.Duration) {
	budget := w.timeout
	if delayMax > 0 && delayMax < budget {
		budget = delayMax
	}
	if w.logger != nil {
		w.logger.Printf("power-watch received %s; running pre-shutdown stop with %s budget", event, budget)
	}
	if err := w.runner.Run(ctx, budget); err != nil && w.logger != nil {
		w.logger.Printf("power-watch pre-shutdown stop: %v", err)
	}
}

func (w *Watch) Status() Status {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.status
}

func (w *Watch) setActive(active bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.status.Active = active
}

func (w *Watch) setDelayMax(delay time.Duration, err error) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.status.InhibitDelayMax = delay
	if err != nil {
		w.status.InhibitDelayMaxError = err.Error()
		return
	}
	if delay < w.timeout {
		w.status.Hint = fmt.Sprintf(
			"logind InhibitDelayMaxSec is %s, shorter than the %s pre-shutdown stop budget; raise InhibitDelayMaxSec in logind.conf",
			delay, w.timeout,
		)
	}
}

func delayDescription(delay time.Duration, err error) string {
	if err != nil {
		return "unknown"
	}
	return delay.String()
}

func (e Event) String() string {
	switch e {
	case PrepareForShutdown:
		return "PrepareForShutdown"
	case shutdownCancelled:
		return "cancelled shutdown"
	default:
		return "unknown power event"
	}
}
