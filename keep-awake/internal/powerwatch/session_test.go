package powerwatch

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"
)

type fakeSessionRequest struct {
	event sessionEvent
	done  chan struct{}
}

type fakeSessionSource struct {
	requests  chan fakeSessionRequest
	mu        sync.Mutex
	created   int
	destroyed int
}

func newFakeSessionSource() *fakeSessionSource {
	return &fakeSessionSource{requests: make(chan fakeSessionRequest)}
}

func (s *fakeSessionSource) Run(ctx context.Context, handle func(sessionEvent)) error {
	for {
		select {
		case <-ctx.Done():
			return nil
		case request := <-s.requests:
			handle(request.event)
			close(request.done)
		}
	}
}

func (s *fakeSessionSource) CreateShutdownBlockReason() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.created++
	return nil
}

func (s *fakeSessionSource) DestroyShutdownBlockReason() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.destroyed++
	return nil
}

func (s *fakeSessionSource) emit(event sessionEvent) {
	done := make(chan struct{})
	s.requests <- fakeSessionRequest{event: event, done: done}
	<-done
}

func (s *fakeSessionSource) blockCounts() (int, int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.created, s.destroyed
}

type fakeSessionHooks struct {
	mu            sync.Mutex
	boxes         []string
	runningErr    error
	runningCalls  int
	queryTimeout  time.Duration
	notifications [][]string
	notifyTimeout time.Duration
	notifyErr     error
	notified      chan struct{}
}

func newFakeSessionHooks(boxes ...string) *fakeSessionHooks {
	return &fakeSessionHooks{boxes: boxes, notified: make(chan struct{}, 4)}
}

func (h *fakeSessionHooks) RunningBoxes(_ context.Context, timeout time.Duration) ([]string, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.runningCalls++
	h.queryTimeout = timeout
	return append([]string(nil), h.boxes...), h.runningErr
}

func (h *fakeSessionHooks) NotifySlept(_ context.Context, boxes []string, timeout time.Duration) error {
	h.mu.Lock()
	h.notifications = append(h.notifications, append([]string(nil), boxes...))
	h.notifyTimeout = timeout
	err := h.notifyErr
	h.mu.Unlock()
	h.notified <- struct{}{}
	return err
}

func (h *fakeSessionHooks) notificationCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.notifications)
}

type memorySuspendStateStore struct {
	mu     sync.Mutex
	state  suspendState
	exists bool
}

func (s *memorySuspendStateStore) Save(state suspendState) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state = state
	s.exists = true
	return nil
}

func (s *memorySuspendStateStore) Load() (suspendState, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.exists {
		return suspendState{}, os.ErrNotExist
	}
	return s.state, nil
}

func (s *memorySuspendStateStore) Clear() error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.state = suspendState{}
	s.exists = false
	return nil
}

type wedgedSessionRunner struct {
	mu      sync.Mutex
	calls   int
	timeout time.Duration
	started chan struct{}
	release chan struct{}
}

func newWedgedSessionRunner() *wedgedSessionRunner {
	return &wedgedSessionRunner{started: make(chan struct{}, 2), release: make(chan struct{})}
}

func (r *wedgedSessionRunner) Run(_ context.Context, timeout time.Duration) error {
	r.mu.Lock()
	r.calls++
	r.timeout = timeout
	r.mu.Unlock()
	r.started <- struct{}{}
	<-r.release
	return nil
}

func (r *wedgedSessionRunner) callCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.calls
}

func TestWindowsShutdownStartsHookBlocksAndReturnsAtBound(t *testing.T) {
	source := newFakeSessionSource()
	runner := newWedgedSessionRunner()
	watch := newSessionWatch(source, newFakeSessionHooks(), &memorySuspendStateStore{}, runner, 20*time.Millisecond, nil)
	cancel, done := runSessionWatch(watch)

	startedAt := time.Now()
	emitted := make(chan struct{})
	go func() {
		source.emit(sessionShutdownQuery)
		close(emitted)
	}()
	select {
	case <-runner.started:
	case <-time.After(time.Second):
		t.Fatal("shutdown hook did not start promptly")
	}
	select {
	case <-emitted:
	case <-time.After(time.Second):
		t.Fatal("shutdown handler exceeded its bounded timeout")
	}
	if elapsed := time.Since(startedAt); elapsed > 500*time.Millisecond {
		t.Fatalf("shutdown handler took %s, want less than 500ms", elapsed)
	}
	created, destroyed := source.blockCounts()
	if created != 1 || destroyed != 1 {
		t.Fatalf("shutdown block calls = create %d, destroy %d; want 1, 1", created, destroyed)
	}

	source.emit(sessionShutdownEnd)
	if runner.callCount() != 1 {
		t.Fatalf("shutdown hook calls = %d, want 1 across query/end", runner.callCount())
	}
	runner.mu.Lock()
	hookTimeout := runner.timeout
	runner.mu.Unlock()
	if hookTimeout != 20*time.Millisecond {
		t.Fatalf("shutdown hook timeout = %s, want 20ms", hookTimeout)
	}
	close(runner.release)
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func TestSuspendPersistsActualBoxesAndResumeNotifiesThenClears(t *testing.T) {
	source := newFakeSessionSource()
	hooks := newFakeSessionHooks("alpha", "beta")
	state := &memorySuspendStateStore{}
	watch := newSessionWatch(source, hooks, state, &fakeRunner{}, time.Minute, nil)
	wantTime := time.Date(2026, 8, 9, 12, 0, 0, 0, time.FixedZone("test", 3600))
	watch.now = func() time.Time { return wantTime }
	cancel, done := runSessionWatch(watch)

	source.emit(sessionSuspend)
	persisted, err := state.Load()
	if err != nil {
		t.Fatalf("Load returned %v", err)
	}
	if !persisted.SuspendedAt.Equal(wantTime) || persisted.SuspendedAt.Location() != time.UTC {
		t.Fatalf("suspend time = %v, want %v in UTC", persisted.SuspendedAt, wantTime)
	}
	if !reflect.DeepEqual(persisted.Boxes, []string{"alpha", "beta"}) {
		t.Fatalf("persisted boxes = %v", persisted.Boxes)
	}
	hooks.mu.Lock()
	queryTimeout := hooks.queryTimeout
	hooks.mu.Unlock()
	if queryTimeout != suspendQueryTimeout {
		t.Fatalf("suspend query timeout = %s, want %s", queryTimeout, suspendQueryTimeout)
	}

	source.emit(sessionResume)
	select {
	case <-hooks.notified:
	case <-time.After(time.Second):
		t.Fatal("resume notification did not run")
	}
	if _, err := state.Load(); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("state after resume Load error = %v, want not exist", err)
	}
	hooks.mu.Lock()
	notification := append([]string(nil), hooks.notifications[0]...)
	notifyTimeout := hooks.notifyTimeout
	hooks.mu.Unlock()
	if !reflect.DeepEqual(notification, []string{"alpha", "beta"}) || notifyTimeout != resumeHookTimeout {
		t.Fatalf("notification = %v with timeout %s", notification, notifyTimeout)
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func TestResumePreservesStateUntilNotificationSucceeds(t *testing.T) {
	source := newFakeSessionSource()
	hooks := newFakeSessionHooks("alpha")
	hooks.notifyErr = errors.New("notification unavailable")
	state := &memorySuspendStateStore{}
	watch := newSessionWatch(source, hooks, state, &fakeRunner{}, time.Minute, nil)
	cancel, done := runSessionWatch(watch)

	source.emit(sessionSuspend)
	source.emit(sessionResume)
	<-hooks.notified
	if persisted, err := state.Load(); err != nil || !reflect.DeepEqual(persisted.Boxes, []string{"alpha"}) {
		t.Fatalf("state after failed notification = %+v, %v; want alpha preserved", persisted, err)
	}

	hooks.mu.Lock()
	hooks.notifyErr = nil
	hooks.mu.Unlock()
	source.emit(sessionResume)
	<-hooks.notified
	waitFor(t, func() bool {
		_, err := state.Load()
		return errors.Is(err, os.ErrNotExist)
	})

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func TestCancelledShutdownCanBeAttemptedAgain(t *testing.T) {
	source := newFakeSessionSource()
	runner := &fakeRunner{}
	watch := newSessionWatch(source, newFakeSessionHooks(), &memorySuspendStateStore{}, runner, time.Minute, nil)
	cancel, done := runSessionWatch(watch)

	source.emit(sessionShutdownQuery)
	source.emit(sessionShutdownCancelled)
	source.emit(sessionShutdownQuery)
	if runner.CallCount() != 2 {
		t.Fatalf("shutdown hook calls = %d, want 2 after cancellation", runner.CallCount())
	}
	created, destroyed := source.blockCounts()
	if created != 2 || destroyed != 2 {
		t.Fatalf("shutdown block calls = create %d, destroy %d; want 2, 2", created, destroyed)
	}

	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func TestIdlePredictedStopSuppressesResumeNotification(t *testing.T) {
	source := newFakeSessionSource()
	hooks := newFakeSessionHooks()
	state := &memorySuspendStateStore{}
	watch := newSessionWatch(source, hooks, state, &fakeRunner{}, time.Minute, nil)
	cancel, done := runSessionWatch(watch)

	// The prior idle-prediction hook has already emptied Docker. The suspend
	// query therefore records the actual empty set rather than the prediction.
	source.emit(sessionSuspend)
	source.emit(sessionResume)
	time.Sleep(20 * time.Millisecond)
	if hooks.notificationCount() != 0 {
		t.Fatalf("notifications = %d, want 0", hooks.notificationCount())
	}
	if _, err := state.Load(); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("state after empty resume Load error = %v, want not exist", err)
	}

	cancel()
	<-done
}

func TestSuspendQueryFailureClearsStaleState(t *testing.T) {
	source := newFakeSessionSource()
	hooks := newFakeSessionHooks("stale")
	hooks.runningErr = errors.New("WSL unavailable")
	state := &memorySuspendStateStore{state: suspendState{Boxes: []string{"stale"}}, exists: true}
	watch := newSessionWatch(source, hooks, state, &fakeRunner{}, time.Minute, nil)
	cancel, done := runSessionWatch(watch)

	source.emit(sessionSuspend)
	source.emit(sessionResume)
	time.Sleep(20 * time.Millisecond)
	if hooks.notificationCount() != 0 {
		t.Fatalf("notifications = %d, want 0 after failed query", hooks.notificationCount())
	}

	cancel()
	<-done
}

func TestFileSuspendStateLifecycle(t *testing.T) {
	path := filepath.Join(t.TempDir(), "nested", "suspend.json")
	store, err := newFileSuspendStateStore(path)
	if err != nil {
		t.Fatalf("newFileSuspendStateStore returned %v", err)
	}
	want := suspendState{SuspendedAt: time.Date(2026, 8, 9, 10, 11, 12, 0, time.UTC), Boxes: []string{"alpha"}}
	if err := store.Save(want); err != nil {
		t.Fatalf("Save returned %v", err)
	}
	got, err := store.Load()
	if err != nil {
		t.Fatalf("Load returned %v", err)
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("loaded state = %+v, want %+v", got, want)
	}
	if err := store.Clear(); err != nil {
		t.Fatalf("Clear returned %v", err)
	}
	if _, err := store.Load(); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("Load after Clear error = %v, want not exist", err)
	}
}

func runSessionWatch(watch *sessionWatch) (context.CancelFunc, <-chan error) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watch.Run(ctx) }()
	return cancel, done
}
