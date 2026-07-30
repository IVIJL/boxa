//go:build windows

package inhibit

import (
	"errors"
	"fmt"
	"runtime"
	"sync"
	"syscall"
)

const (
	esSystemRequired uintptr = 0x00000001
	esContinuous     uintptr = 0x80000000
)

var (
	setThreadExecutionState = syscall.NewLazyDLL("kernel32.dll").NewProc("SetThreadExecutionState")
	errInhibitorClosed      = errors.New("Windows sleep inhibitor is closed")
)

type operation uint8

const (
	operationAcquire operation = iota
	operationRelease
	operationClose
)

type request struct {
	operation operation
	result    chan error
}

type platformInhibitor struct {
	mu       sync.Mutex
	requests chan request
	done     chan struct{}
	active   bool
	closed   bool
}

// New returns a Windows inhibitor backed by SetThreadExecutionState. A single
// dedicated OS thread owns the execution state for the inhibitor's lifetime.
func New() Inhibitor {
	p := &platformInhibitor{
		requests: make(chan request),
		done:     make(chan struct{}),
	}
	go p.run()
	return p
}

func (p *platformInhibitor) Acquire() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return errInhibitorClosed
	}
	if p.active {
		return nil
	}

	if err := p.execute(operationAcquire); err != nil {
		return err
	}
	p.active = true
	return nil
}

func (p *platformInhibitor) Release() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed || !p.active {
		return nil
	}

	if err := p.execute(operationRelease); err != nil {
		// Keep reporting the inhibitor as active because clearing the execution
		// state failed and the dedicated thread is still alive.
		return err
	}
	p.active = false
	return nil
}

func (p *platformInhibitor) Active() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.active && !p.closed
}

func (p *platformInhibitor) Close() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.closed {
		return nil
	}

	err := p.execute(operationClose)
	<-p.done
	p.active = false
	p.closed = true
	return err
}

func (p *platformInhibitor) execute(op operation) error {
	result := make(chan error, 1)
	p.requests <- request{operation: op, result: result}
	return <-result
}

func (p *platformInhibitor) run() {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	defer close(p.done)

	for req := range p.requests {
		var err error
		switch req.operation {
		case operationAcquire:
			err = callSetThreadExecutionState(esContinuous | esSystemRequired)
		case operationRelease:
			err = callSetThreadExecutionState(esContinuous)
		case operationClose:
			err = callSetThreadExecutionState(esContinuous)
			req.result <- err
			return
		}
		req.result <- err
	}
}

func callSetThreadExecutionState(state uintptr) error {
	previousState, _, callErr := setThreadExecutionState.Call(state)
	if previousState != 0 {
		return nil
	}
	if callErr != syscall.Errno(0) {
		return fmt.Errorf("SetThreadExecutionState(0x%08x): %w", state, callErr)
	}
	return fmt.Errorf("SetThreadExecutionState(0x%08x) failed", state)
}
