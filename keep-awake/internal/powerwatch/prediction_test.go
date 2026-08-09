package powerwatch

import (
	"bytes"
	"context"
	"errors"
	"log"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeIdleSource struct {
	mu   sync.Mutex
	idle time.Duration
	err  error
}

func (s *fakeIdleSource) IdleTime() (time.Duration, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.idle, s.err
}

func (s *fakeIdleSource) Set(idle time.Duration) {
	s.mu.Lock()
	s.idle = idle
	s.mu.Unlock()
}

type fakeTimeoutSource struct {
	mu      sync.Mutex
	timeout time.Duration
	err     error
	calls   int
}

func (s *fakeTimeoutSource) SleepTimeout(context.Context) (time.Duration, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	return s.timeout, s.err
}

func (s *fakeTimeoutSource) CallCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

type fakePredictionScheduler struct {
	mu     sync.Mutex
	timers []*fakePredictionTimer
}

type fakePredictionTimer struct {
	mu      sync.Mutex
	delay   time.Duration
	ch      chan time.Time
	stopped bool
}

func (s *fakePredictionScheduler) NewTimer(delay time.Duration) predictionTimer {
	timer := &fakePredictionTimer{delay: delay, ch: make(chan time.Time, 1)}
	s.mu.Lock()
	s.timers = append(s.timers, timer)
	s.mu.Unlock()
	return timer
}

func (t *fakePredictionTimer) Chan() <-chan time.Time { return t.ch }

func (t *fakePredictionTimer) Stop() {
	t.mu.Lock()
	t.stopped = true
	t.mu.Unlock()
}

func (t *fakePredictionTimer) fire() bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.stopped {
		return false
	}
	t.stopped = true
	t.ch <- time.Time{}
	return true
}

func (s *fakePredictionScheduler) fire(delay time.Duration) bool {
	s.mu.Lock()
	timers := append([]*fakePredictionTimer(nil), s.timers...)
	s.mu.Unlock()
	for _, timer := range timers {
		timer.mu.Lock()
		matches := !timer.stopped && timer.delay == delay
		timer.mu.Unlock()
		if matches && timer.fire() {
			return true
		}
	}
	return false
}

func (s *fakePredictionScheduler) hasActive(delay time.Duration) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, timer := range s.timers {
		timer.mu.Lock()
		active := !timer.stopped && timer.delay == delay
		timer.mu.Unlock()
		if active {
			return true
		}
	}
	return false
}

func (s *fakePredictionScheduler) activeCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	count := 0
	for _, timer := range s.timers {
		timer.mu.Lock()
		if !timer.stopped {
			count++
		}
		timer.mu.Unlock()
	}
	return count
}

type fakeLeaseSource struct {
	mu      sync.Mutex
	held    bool
	calls   int
	changes chan struct{}
}

func newFakeLeaseSource(held bool) *fakeLeaseSource {
	return &fakeLeaseSource{held: held, changes: make(chan struct{}, 4)}
}

func (s *fakeLeaseSource) AwakeLeaseHeld() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	return s.held
}

func (s *fakeLeaseSource) AwakeLeaseChanges() <-chan struct{} { return s.changes }

func (s *fakeLeaseSource) Set(held bool) {
	s.mu.Lock()
	s.held = held
	s.mu.Unlock()
	s.changes <- struct{}{}
}

func (s *fakeLeaseSource) CallCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.calls
}

type lockedBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
}

func (b *lockedBuffer) Write(data []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.Write(data)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.String()
}

func TestPredictionSchedulesEarlyAndFinalChecksThenFires(t *testing.T) {
	idle := &fakeIdleSource{}
	settings := &fakeTimeoutSource{timeout: 10 * time.Minute}
	scheduler := &fakePredictionScheduler{}
	runner := &fakeRunner{}
	watch := newPredictionWatch(idle, settings, scheduler, runner, nil, time.Minute, nil)
	cancel, done := runPredictionWatch(watch)

	waitFor(t, func() bool { return scheduler.hasActive(8 * time.Minute) })
	idle.Set(8 * time.Minute)
	if !scheduler.fire(8 * time.Minute) {
		t.Fatal("early timer was not active")
	}
	waitFor(t, func() bool { return scheduler.hasActive(time.Minute) })
	idle.Set(9 * time.Minute)
	if !scheduler.fire(time.Minute) {
		t.Fatal("final timer was not active")
	}
	waitFor(t, func() bool { return runner.CallCount() == 1 })

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func TestPredictionActivityBeforeFinalCheckReschedules(t *testing.T) {
	idle := &fakeIdleSource{}
	scheduler := &fakePredictionScheduler{}
	runner := &fakeRunner{}
	watch := newPredictionWatch(idle, &fakeTimeoutSource{timeout: 10 * time.Minute}, scheduler, runner, nil, time.Minute, nil)
	cancel, done := runPredictionWatch(watch)

	waitFor(t, func() bool { return scheduler.hasActive(8 * time.Minute) })
	idle.Set(8 * time.Minute)
	scheduler.fire(8 * time.Minute)
	waitFor(t, func() bool { return scheduler.hasActive(time.Minute) })
	idle.Set(time.Minute)
	scheduler.fire(time.Minute)
	waitFor(t, func() bool { return scheduler.hasActive(7 * time.Minute) })
	if runner.CallCount() != 0 {
		t.Fatalf("hook calls = %d, want 0", runner.CallCount())
	}

	cancel()
	<-done
}

func TestPredictionSuspendsForLeaseAndResumesOnRelease(t *testing.T) {
	idle := &fakeIdleSource{}
	settings := &fakeTimeoutSource{timeout: 10 * time.Minute}
	scheduler := &fakePredictionScheduler{}
	leases := newFakeLeaseSource(true)
	watch := newPredictionWatch(idle, settings, scheduler, &fakeRunner{}, leases, time.Minute, nil)
	cancel, done := runPredictionWatch(watch)

	waitFor(t, func() bool { return leases.CallCount() > 0 })
	if settings.CallCount() != 0 || scheduler.activeCount() != 0 {
		t.Fatalf("held lease queried settings %d times and left %d timers", settings.CallCount(), scheduler.activeCount())
	}
	leases.Set(false)
	waitFor(t, func() bool { return settings.CallCount() == 1 && scheduler.hasActive(8*time.Minute) })
	leases.Set(true)
	waitFor(t, func() bool { return scheduler.activeCount() == 0 })

	cancel()
	<-done
}

func TestPredictionRearmsOnlyAfterActivityReset(t *testing.T) {
	idle := &fakeIdleSource{idle: 9 * time.Minute}
	scheduler := &fakePredictionScheduler{}
	runner := &fakeRunner{}
	watch := newPredictionWatch(idle, &fakeTimeoutSource{timeout: 10 * time.Minute}, scheduler, runner, nil, time.Minute, nil)
	cancel, done := runPredictionWatch(watch)

	waitFor(t, func() bool { return runner.CallCount() == 1 })
	if !scheduler.fire(settingsRefreshInterval) {
		t.Fatal("settings refresh timer was not active")
	}
	waitFor(t, func() bool { return scheduler.hasActive(settingsRefreshInterval) })
	if runner.CallCount() != 1 {
		t.Fatalf("hook repeated without activity; calls = %d", runner.CallCount())
	}
	idle.Set(0)
	if !scheduler.fire(settingsRefreshInterval) {
		t.Fatal("second settings refresh timer was not active")
	}
	waitFor(t, func() bool { return scheduler.hasActive(8 * time.Minute) })

	cancel()
	<-done
}

func TestPredictionRetriesAfterHookFailure(t *testing.T) {
	idle := &fakeIdleSource{idle: 9 * time.Minute}
	scheduler := &fakePredictionScheduler{}
	runner := &fakeRunner{err: errors.New("stop failed")}
	watch := newPredictionWatch(idle, &fakeTimeoutSource{timeout: 10 * time.Minute}, scheduler, runner, nil, time.Minute, nil)
	cancel, done := runPredictionWatch(watch)

	waitFor(t, func() bool { return runner.CallCount() == 1 })
	waitFor(t, func() bool { return scheduler.hasActive(hookRetryInterval) })
	if watch.waitingForActivity {
		t.Fatal("failed hook suppressed retry until activity")
	}
	runner.mu.Lock()
	runner.err = nil
	runner.mu.Unlock()
	if !scheduler.fire(hookRetryInterval) {
		t.Fatal("hook retry timer was not active")
	}
	waitFor(t, func() bool { return runner.CallCount() == 2 })
	cancel()
	<-done
	if !watch.waitingForActivity {
		t.Fatal("successful retry did not wait for activity")
	}
}

func TestPredictionNeverSleepAndSettingsFailuresDisableWithOneLog(t *testing.T) {
	settings := &fakeTimeoutSource{err: errors.New("powercfg failed")}
	scheduler := &fakePredictionScheduler{}
	var output lockedBuffer
	watch := newPredictionWatch(&fakeIdleSource{}, settings, scheduler, &fakeRunner{}, nil, time.Minute, log.New(&output, "", 0))
	cancel, done := runPredictionWatch(watch)

	waitFor(t, func() bool { return strings.Count(output.String(), "powercfg failed") == 1 })
	if scheduler.hasActive(0) || strings.Count(output.String(), "powercfg failed") != 1 {
		t.Fatalf("initial failure state: timers=%d log=%q", scheduler.activeCount(), output.String())
	}
	scheduler.fire(settingsRefreshInterval)
	waitFor(t, func() bool { return settings.CallCount() == 2 })
	if strings.Count(output.String(), "powercfg failed") != 1 {
		t.Fatalf("repeated failure log = %q", output.String())
	}

	settings.mu.Lock()
	settings.err = nil
	settings.timeout = 0
	settings.mu.Unlock()
	scheduler.fire(settingsRefreshInterval)
	waitFor(t, func() bool { return settings.CallCount() == 3 })
	if scheduler.activeCount() != 1 {
		t.Fatalf("never-sleep plan left %d timers, want refresh only", scheduler.activeCount())
	}

	cancel()
	<-done
}

func TestPredictionSettingsRefreshUsesChangedTimeout(t *testing.T) {
	settings := &fakeTimeoutSource{timeout: 10 * time.Minute}
	scheduler := &fakePredictionScheduler{}
	watch := newPredictionWatch(&fakeIdleSource{}, settings, scheduler, &fakeRunner{}, nil, time.Minute, nil)
	cancel, done := runPredictionWatch(watch)

	waitFor(t, func() bool { return scheduler.hasActive(8 * time.Minute) })
	settings.mu.Lock()
	settings.timeout = 20 * time.Minute
	settings.mu.Unlock()
	if !scheduler.fire(settingsRefreshInterval) {
		t.Fatal("settings refresh timer was not active")
	}
	waitFor(t, func() bool { return scheduler.hasActive(18 * time.Minute) })
	if settings.CallCount() != 2 {
		t.Fatalf("settings calls = %d, want 2", settings.CallCount())
	}

	cancel()
	<-done
}

func TestParsePowercfgTimeouts(t *testing.T) {
	output := `
    Current AC Power Setting Index: 0x00000e10
    Current DC Power Setting Index: 0x0000012c
`
	timeouts, err := parsePowercfgTimeouts(output)
	if err != nil {
		t.Fatalf("parsePowercfgTimeouts returned %v", err)
	}
	if timeouts.ac != time.Hour || timeouts.dc != 5*time.Minute {
		t.Fatalf("timeouts = %+v", timeouts)
	}
	if _, err := parsePowercfgTimeouts("missing values"); err == nil {
		t.Fatal("missing settings parsed without error")
	}
}

func runPredictionWatch(watch *predictionWatch) (context.CancelFunc, <-chan error) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watch.Run(ctx) }()
	return cancel, done
}
