package powerwatch

import (
	"bytes"
	"context"
	"errors"
	"io"
	"log"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeSource struct {
	mu           sync.Mutex
	events       chan Event
	delayMax     time.Duration
	acquireCalls int
	releaseCalls int
}

type fakeLock struct {
	once   sync.Once
	source *fakeSource
}

type fakeRunner struct {
	mu    sync.Mutex
	calls int
	err   error
}

func newFakeSource(delayMax time.Duration) *fakeSource {
	return &fakeSource{events: make(chan Event, 4), delayMax: delayMax}
}

func (s *fakeSource) Subscribe(context.Context) (<-chan Event, error) {
	return s.events, nil
}

func (s *fakeSource) Acquire(context.Context) (delayLock, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.acquireCalls++
	return &fakeLock{source: s}, nil
}

func (s *fakeSource) InhibitDelayMax(context.Context) (time.Duration, error) {
	return s.delayMax, nil
}

func (s *fakeSource) Close() error { return nil }

func (s *fakeSource) ReleaseCalls() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.releaseCalls
}

func (l *fakeLock) Release() error {
	l.once.Do(func() {
		l.source.mu.Lock()
		defer l.source.mu.Unlock()
		l.source.releaseCalls++
	})
	return nil
}

func (r *fakeRunner) Run(context.Context, time.Duration) error {
	r.mu.Lock()
	r.calls++
	r.mu.Unlock()
	return r.err
}

func (r *fakeRunner) CallCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.calls
}

func TestPowerEventsRunHookAndReleaseDelayLock(t *testing.T) {
	for _, event := range []Event{PrepareForSleep, PrepareForShutdown} {
		t.Run(event.String(), func(t *testing.T) {
			source := newFakeSource(time.Minute)
			runner := &fakeRunner{}
			watch := newWatch(source, runner, time.Minute, nil)
			cancel, done := runWatch(t, watch)

			source.events <- event
			waitFor(t, func() bool { return source.ReleaseCalls() == 1 })
			if runner.CallCount() != 1 {
				t.Fatalf("hook calls = %d, want 1", runner.CallCount())
			}

			cancel()
			if err := <-done; err != nil {
				t.Fatalf("Run returned %v", err)
			}
		})
	}
}

func TestHookFailureIsLoggedAndReleasesDelayLock(t *testing.T) {
	source := newFakeSource(time.Minute)
	runner := &fakeRunner{err: errors.New("stop failed")}
	var output bytes.Buffer
	watch := newWatch(source, runner, time.Minute, log.New(&output, "", 0))
	cancel, done := runWatch(t, watch)

	source.events <- PrepareForSleep
	waitFor(t, func() bool { return source.ReleaseCalls() == 1 })
	if !strings.Contains(output.String(), "stop failed") {
		t.Fatalf("log = %q, want hook failure", output.String())
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func TestHookTimeoutIsEnforcedAndReleasesDelayLock(t *testing.T) {
	source := newFakeSource(time.Minute)
	var output bytes.Buffer
	watch := newWatch(
		source,
		commandRunner{command: "exec sleep 10", output: io.Discard},
		20*time.Millisecond,
		log.New(&output, "", 0),
	)
	cancel, done := runWatch(t, watch)

	started := time.Now()
	source.events <- PrepareForShutdown
	waitFor(t, func() bool { return source.ReleaseCalls() == 1 })
	if elapsed := time.Since(started); elapsed > time.Second {
		t.Fatalf("hook release took %s, want less than 1s", elapsed)
	}
	if !strings.Contains(output.String(), "timed out after 20ms") {
		t.Fatalf("log = %q, want timeout", output.String())
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func TestResumeReacquiresDelayLock(t *testing.T) {
	source := newFakeSource(time.Minute)
	watch := newWatch(source, &fakeRunner{}, time.Minute, nil)
	cancel, done := runWatch(t, watch)

	source.events <- PrepareForSleep
	waitFor(t, func() bool { return source.ReleaseCalls() == 1 })
	source.events <- resumeFromSleep
	waitFor(t, func() bool { return watch.Status().Active })

	source.mu.Lock()
	acquireCalls := source.acquireCalls
	source.mu.Unlock()
	if acquireCalls != 2 {
		t.Fatalf("acquire calls = %d, want 2", acquireCalls)
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func TestStatusHintsWhenLogindDelayIsShorterThanBudget(t *testing.T) {
	source := newFakeSource(5 * time.Second)
	watch := newWatch(source, &fakeRunner{}, time.Minute, nil)
	cancel, done := runWatch(t, watch)

	status := watch.Status()
	if !status.Active || status.InhibitDelayMax != 5*time.Second {
		t.Fatalf("unexpected status: %+v", status)
	}
	if !strings.Contains(status.Hint, "raise InhibitDelayMaxSec") {
		t.Fatalf("hint = %q", status.Hint)
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func runWatch(t *testing.T, watch *Watch) (context.CancelFunc, <-chan error) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watch.Run(ctx) }()
	waitFor(t, func() bool { return watch.Status().Active })
	return cancel, done
}

func waitFor(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for condition")
		}
		time.Sleep(time.Millisecond)
	}
}
