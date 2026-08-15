package powerwatch

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"log"
	"os/exec"
	"sync"
	"time"
)

const (
	warmHookInitialBackoff = time.Second
	warmHookMaximumBackoff = 30 * time.Second
)

type warmHookCommand func() (*exec.Cmd, error)

// WarmHook keeps a pre-spawned WSL stop helper available for Windows shutdown.
type WarmHook struct {
	mu sync.Mutex

	enabled bool
	command warmHookCommand
	output  io.Writer
	logger  *log.Logger
	initial time.Duration
	maximum time.Duration

	armed    bool
	alive    bool
	child    *warmHookChild
	cancel   context.CancelFunc
	loopDone chan struct{}
}

type warmHookChild struct {
	stdin io.WriteCloser

	ready      chan struct{}
	noBoxes    chan struct{}
	done       chan struct{}
	exited     chan struct{}
	outputDone chan struct{}

	readyOnce   sync.Once
	noBoxesOnce sync.Once
	doneOnce    sync.Once
	exitErr     error
}

func NewWarmHook(output io.Writer, logger *log.Logger) *WarmHook {
	return &WarmHook{
		enabled: warmHookSupported(),
		command: newWarmHookCommand,
		output:  output,
		logger:  logger,
		initial: warmHookInitialBackoff,
		maximum: warmHookMaximumBackoff,
	}
}

func newWarmHook(command warmHookCommand, output io.Writer, logger *log.Logger, initial, maximum time.Duration) *WarmHook {
	return &WarmHook{
		enabled: true,
		command: command,
		output:  output,
		logger:  logger,
		initial: initial,
		maximum: maximum,
	}
}

// Status reports whether the warm hook is armed and its child is ready.
func (h *WarmHook) Status() (armed, alive bool) {
	if h == nil || !h.enabled {
		return false, false
	}

	h.mu.Lock()
	defer h.mu.Unlock()
	return h.armed, h.alive
}

// Arm starts maintaining a warm stop helper. It is a no-op off Windows.
func (h *WarmHook) Arm() {
	if h == nil || !h.enabled {
		return
	}

	h.mu.Lock()
	if h.armed {
		h.mu.Unlock()
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	h.armed = true
	h.cancel = cancel
	h.loopDone = done
	h.mu.Unlock()

	go h.maintain(ctx, done)
}

// DisarmAsync synchronously marks the hook disarmed and starts child cleanup.
func (h *WarmHook) DisarmAsync() {
	h.beginDisarm()
}

// Disarm closes the helper's stdin and waits for the child to be reaped.
func (h *WarmHook) Disarm() {
	done := h.beginDisarm()
	if done != nil {
		<-done
	}
}

func (h *WarmHook) beginDisarm() <-chan struct{} {
	if h == nil || !h.enabled {
		return nil
	}

	h.mu.Lock()
	if !h.armed && h.loopDone == nil {
		h.mu.Unlock()
		return nil
	}
	h.armed = false
	cancel := h.cancel
	child := h.child
	done := h.loopDone
	if cancel != nil {
		cancel()
	}
	if child != nil {
		_ = child.stdin.Close()
	}
	h.mu.Unlock()
	return done
}

func (h *WarmHook) stop(ctx context.Context) (bool, error) {
	if h == nil || !h.enabled {
		return false, nil
	}

	h.mu.Lock()
	if !h.alive || h.child == nil {
		h.mu.Unlock()
		return false, nil
	}
	child := h.child
	_, err := io.WriteString(child.stdin, "stop\n")
	h.mu.Unlock()
	if err != nil {
		h.logf("signal warm hook: %v; falling back to direct shutdown command", err)
		return false, fmt.Errorf("signal warm hook: %w", err)
	}

	select {
	case <-child.done:
		return true, nil
	case <-child.exited:
		if child.exitErr != nil {
			return true, fmt.Errorf("warm hook exited: %w", child.exitErr)
		}
		return true, nil
	case <-ctx.Done():
		return true, ctx.Err()
	}
}

func (h *WarmHook) maintain(ctx context.Context, loopDone chan struct{}) {
	defer func() {
		h.mu.Lock()
		if h.loopDone == loopDone {
			h.armed = false
			h.alive = false
			h.child = nil
			h.cancel = nil
			h.loopDone = nil
		}
		h.mu.Unlock()
		close(loopDone)
	}()

	backoff := h.initial
	for {
		child, err := h.startChild()
		if err != nil {
			h.logf("start warm hook: %v", err)
			if !waitWarmHookBackoff(ctx, backoff) {
				return
			}
			backoff = nextWarmHookBackoff(backoff, h.maximum)
			continue
		}

		h.mu.Lock()
		if ctx.Err() != nil {
			h.mu.Unlock()
			_ = child.stdin.Close()
			<-child.exited
			return
		}
		h.child = child
		h.mu.Unlock()

		result := h.waitForChild(ctx, child)
		if result == warmHookNoBoxes || result == warmHookDisarmed {
			return
		}
		if child.exitErr != nil {
			h.logf("warm hook exited: %v", child.exitErr)
		} else {
			h.logf("warm hook exited before shutdown")
		}
		if !waitWarmHookBackoff(ctx, backoff) {
			return
		}
		backoff = nextWarmHookBackoff(backoff, h.maximum)
	}
}

type warmHookResult uint8

const (
	warmHookExited warmHookResult = iota
	warmHookNoBoxes
	warmHookDisarmed
)

func (h *WarmHook) waitForChild(ctx context.Context, child *warmHookChild) warmHookResult {
	ready := child.ready
	for {
		select {
		case <-ready:
			h.mu.Lock()
			if h.child == child {
				h.alive = true
			}
			h.mu.Unlock()
			ready = nil
		case <-child.noBoxes:
			h.mu.Lock()
			if h.child == child {
				h.armed = false
				h.alive = false
			}
			h.mu.Unlock()
			<-child.exited
			return warmHookNoBoxes
		case <-child.exited:
			select {
			case <-child.noBoxes:
				h.clearChild(child)
				return warmHookNoBoxes
			default:
			}
			h.clearChild(child)
			return warmHookExited
		case <-ctx.Done():
			_ = child.stdin.Close()
			<-child.exited
			h.clearChild(child)
			return warmHookDisarmed
		}
	}
}

func (h *WarmHook) startChild() (*warmHookChild, error) {
	cmd, err := h.command()
	if err != nil {
		return nil, err
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, fmt.Errorf("open warm-hook stdin: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("open warm-hook stdout: %w", err)
	}
	cmd.Stderr = h.output
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		return nil, fmt.Errorf("spawn warm hook: %w", err)
	}

	child := &warmHookChild{
		stdin:      stdin,
		ready:      make(chan struct{}),
		noBoxes:    make(chan struct{}),
		done:       make(chan struct{}),
		exited:     make(chan struct{}),
		outputDone: make(chan struct{}),
	}
	go h.readChildOutput(stdout, child)
	go func() {
		<-child.outputDone
		child.exitErr = cmd.Wait()
		close(child.exited)
	}()
	return child, nil
}

func (h *WarmHook) readChildOutput(stdout io.Reader, child *warmHookChild) {
	defer close(child.outputDone)
	scanner := bufio.NewScanner(stdout)
	for scanner.Scan() {
		line := scanner.Text()
		if h.output != nil {
			fmt.Fprintln(h.output, line)
		}
		switch line {
		case "ready":
			child.readyOnce.Do(func() { close(child.ready) })
		case "no-boxes":
			child.noBoxesOnce.Do(func() { close(child.noBoxes) })
		case "done":
			child.doneOnce.Do(func() { close(child.done) })
		}
	}
	if err := scanner.Err(); err != nil {
		h.logf("read warm-hook output: %v", err)
	}
}

func (h *WarmHook) clearChild(child *warmHookChild) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.child == child {
		h.child = nil
		h.alive = false
	}
}

func (h *WarmHook) logf(format string, args ...any) {
	if h.logger != nil {
		h.logger.Printf(format, args...)
	}
}

func waitWarmHookBackoff(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-timer.C:
		return true
	case <-ctx.Done():
		return false
	}
}

func nextWarmHookBackoff(current, maximum time.Duration) time.Duration {
	next := current * 2
	if next > maximum {
		return maximum
	}
	return next
}
