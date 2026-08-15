package powerwatch

import (
	"context"
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
	watch := newSessionWatch(source, runner, nil, 20*time.Millisecond, nil)
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
	close(runner.release)
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("Run returned %v", err)
	}
}

func TestWindowsShutdownHookIsCappedAt45Seconds(t *testing.T) {
	source := newFakeSessionSource()
	runner := newWedgedSessionRunner()
	watch := newSessionWatch(source, runner, nil, time.Minute, nil)

	done := make(chan struct{})
	go func() {
		watch.handleShutdown(context.Background())
		close(done)
	}()
	<-runner.started
	runner.mu.Lock()
	timeout := runner.timeout
	runner.mu.Unlock()
	if timeout != 45*time.Second {
		t.Fatalf("shutdown hook timeout = %s, want 45s", timeout)
	}
	close(runner.release)
	<-done
}

func TestCancelledShutdownCanBeAttemptedAgain(t *testing.T) {
	source := newFakeSessionSource()
	runner := &fakeRunner{}
	watch := newSessionWatch(source, runner, nil, time.Minute, nil)
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

func runSessionWatch(watch *sessionWatch) (context.CancelFunc, <-chan error) {
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- watch.Run(ctx) }()
	return cancel, done
}
