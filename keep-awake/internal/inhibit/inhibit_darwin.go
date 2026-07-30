//go:build darwin

package inhibit

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sync"
)

type platformInhibitor struct {
	mu   sync.Mutex
	cmd  *exec.Cmd
	done chan error
}

// New returns a macOS inhibitor backed by a managed caffeinate process. The
// -i assertion prevents idle system sleep but does not force the display on.
func New() Inhibitor { return &platformInhibitor{} }

func (p *platformInhibitor) Acquire() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.activeLocked() {
		return nil
	}

	cmd := exec.Command("caffeinate", "-i")
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start caffeinate: %w", err)
	}
	done := make(chan error, 1)
	p.cmd = cmd
	p.done = done
	go func() {
		done <- cmd.Wait()
		close(done)
	}()
	return nil
}

func (p *platformInhibitor) Release() error {
	p.mu.Lock()
	if !p.activeLocked() {
		p.cmd = nil
		p.done = nil
		p.mu.Unlock()
		return nil
	}
	cmd := p.cmd
	done := p.done
	p.cmd = nil
	p.done = nil
	p.mu.Unlock()

	if err := cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
		return fmt.Errorf("stop caffeinate: %w", err)
	}
	<-done
	return nil
}

func (p *platformInhibitor) Active() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.activeLocked()
}

func (p *platformInhibitor) activeLocked() bool {
	if p.cmd == nil || p.done == nil {
		return false
	}
	select {
	case <-p.done:
		p.cmd = nil
		p.done = nil
		return false
	default:
		return true
	}
}

func (p *platformInhibitor) Close() error { return p.Release() }
