//go:build linux

package powerwatch

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"time"

	"github.com/godbus/dbus/v5"
)

const (
	loginDestination = "org.freedesktop.login1"
	loginPath        = dbus.ObjectPath("/org/freedesktop/login1")
	managerInterface = "org.freedesktop.login1.Manager"
)

type logindSource struct {
	mu      sync.Mutex
	conn    *dbus.Conn
	signals chan *dbus.Signal
	events  chan Event
}

type logindLock struct {
	once sync.Once
	file *os.File
	err  error
}

func newPlatformSource() eventSource { return &logindSource{} }

func configureCommand(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return os.ErrProcessDone
		}
		err := syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		if errors.Is(err, syscall.ESRCH) {
			return os.ErrProcessDone
		}
		return err
	}
}

func (s *logindSource) Subscribe(ctx context.Context) (<-chan Event, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, fmt.Errorf("connect to system bus: %w", err)
	}
	if err := conn.AddMatchSignal(
		dbus.WithMatchObjectPath(loginPath),
		dbus.WithMatchInterface(managerInterface),
		dbus.WithMatchMember("PrepareForSleep"),
	); err != nil {
		conn.Close()
		return nil, fmt.Errorf("subscribe PrepareForSleep: %w", err)
	}
	if err := conn.AddMatchSignal(
		dbus.WithMatchObjectPath(loginPath),
		dbus.WithMatchInterface(managerInterface),
		dbus.WithMatchMember("PrepareForShutdown"),
	); err != nil {
		conn.Close()
		return nil, fmt.Errorf("subscribe PrepareForShutdown: %w", err)
	}

	s.mu.Lock()
	s.conn = conn
	s.signals = make(chan *dbus.Signal, 8)
	s.events = make(chan Event, 8)
	signals := s.signals
	events := s.events
	s.mu.Unlock()
	conn.Signal(signals)
	go forwardSignals(ctx, signals, events)
	return events, nil
}

func (s *logindSource) Acquire(ctx context.Context) (delayLock, error) {
	s.mu.Lock()
	conn := s.conn
	s.mu.Unlock()
	if conn == nil {
		return nil, fmt.Errorf("system bus is not connected")
	}

	var fd dbus.UnixFD
	err := conn.Object(loginDestination, loginPath).
		CallWithContext(ctx, managerInterface+".Inhibit", 0,
			"sleep:shutdown",
			"boxa-keep-awake",
			"Stopping boxa containers before sleep or shutdown",
			"delay",
		).Store(&fd)
	if err != nil {
		return nil, fmt.Errorf("call logind Inhibit: %w", err)
	}
	return &logindLock{file: os.NewFile(uintptr(fd), "logind-delay-inhibitor")}, nil
}

func (s *logindSource) InhibitDelayMax(ctx context.Context) (time.Duration, error) {
	s.mu.Lock()
	conn := s.conn
	s.mu.Unlock()
	if conn == nil {
		return 0, fmt.Errorf("system bus is not connected")
	}
	property, err := conn.Object(loginDestination, loginPath).
		GetProperty(managerInterface + ".InhibitDelayMaxUSec")
	if err != nil {
		return 0, fmt.Errorf("get InhibitDelayMaxUSec: %w", err)
	}
	microseconds, ok := property.Value().(uint64)
	if !ok {
		return 0, fmt.Errorf("InhibitDelayMaxUSec has type %T, want uint64", property.Value())
	}
	return time.Duration(microseconds) * time.Microsecond, nil
}

func (s *logindSource) Close() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.conn == nil {
		return nil
	}
	if s.signals != nil {
		s.conn.RemoveSignal(s.signals)
	}
	err := s.conn.Close()
	s.conn = nil
	s.signals = nil
	s.events = nil
	return err
}

func (l *logindLock) Release() error {
	l.once.Do(func() {
		if l.file != nil {
			l.err = l.file.Close()
		}
	})
	return l.err
}

func forwardSignals(ctx context.Context, signals <-chan *dbus.Signal, events chan<- Event) {
	defer close(events)
	for {
		select {
		case <-ctx.Done():
			return
		case signal, ok := <-signals:
			if !ok {
				return
			}
			if len(signal.Body) != 1 {
				continue
			}
			preparing, ok := signal.Body[0].(bool)
			if !ok {
				continue
			}
			var event Event
			switch signal.Name {
			case managerInterface + ".PrepareForSleep":
				if preparing {
					event = PrepareForSleep
				} else {
					event = resumeFromSleep
				}
			case managerInterface + ".PrepareForShutdown":
				if preparing {
					event = PrepareForShutdown
				} else {
					event = shutdownCancelled
				}
			default:
				continue
			}
			select {
			case events <- event:
			case <-ctx.Done():
				return
			}
		}
	}
}
