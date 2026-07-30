//go:build linux

package inhibit

import (
	"errors"
	"fmt"
	"os/exec"
	"sync"
	"syscall"
)

type platformInhibitor struct {
	mu   sync.Mutex
	cmd  *exec.Cmd
	done chan error
}

// New returns a Linux inhibitor backed by systemd-logind through the
// systemd-inhibit command. The child process is isolated in a process group so
// Release can reliably terminate both systemd-inhibit and its sleep payload.
func New() Inhibitor { return &platformInhibitor{} }

func (p *platformInhibitor) Acquire() error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.activeLocked() {
		return nil
	}

	cmd := exec.Command(
		"systemd-inhibit",
		"--what=idle:sleep",
		"--who=boxa-keep-awake",
		"--why=Coding agent is working",
		"--mode=block",
		"sleep", "infinity",
	)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start systemd-inhibit: %w", err)
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

	err := syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	if err != nil && !errors.Is(err, syscall.ESRCH) {
		return fmt.Errorf("stop systemd-inhibit: %w", err)
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
