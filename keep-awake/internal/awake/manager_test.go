package awake

import (
	"bytes"
	"context"
	"log"
	"strings"
	"testing"
	"time"

	"github.com/IVIJL/boxa/keep-awake/internal/inhibit"
)

func TestManagerTransitionsFakeInhibitor(t *testing.T) {
	clock := &fakeClock{now: time.Date(2026, 7, 30, 12, 0, 0, 0, time.UTC)}
	fake := &inhibit.Fake{}
	manager := NewManager(NewRegistry(clock, 0, nil), fake, nil)

	if err := manager.Busy("codex", "box-a", 10*time.Second); err != nil {
		t.Fatalf("first Busy: %v", err)
	}
	if !fake.Active() || fake.AcquireCalls() != 1 {
		t.Fatalf("after first busy: active=%v acquire calls=%d", fake.Active(), fake.AcquireCalls())
	}
	if err := manager.Busy("codex", "box-b", 20*time.Second); err != nil {
		t.Fatalf("second Busy: %v", err)
	}
	if fake.AcquireCalls() != 1 {
		t.Fatalf("second holder reacquired inhibitor; calls=%d", fake.AcquireCalls())
	}
	if err := manager.Idle("codex", "box-a"); err != nil {
		t.Fatalf("Idle: %v", err)
	}
	if !fake.Active() || fake.ReleaseCalls() != 0 {
		t.Fatalf("one session idled while another holds: active=%v release calls=%d", fake.Active(), fake.ReleaseCalls())
	}

	clock.Advance(20 * time.Second)
	if err := manager.Reconcile(); err != nil {
		t.Fatalf("Reconcile: %v", err)
	}
	if fake.Active() || fake.ReleaseCalls() != 1 {
		t.Fatalf("expired holder did not release inhibitor: active=%v release calls=%d", fake.Active(), fake.ReleaseCalls())
	}
}

func TestManagerRetriesFailedAcquire(t *testing.T) {
	clock := &fakeClock{}
	fake := &inhibit.Fake{}
	fake.SetAcquireError(assertionError("unavailable"))
	manager := NewManager(NewRegistry(clock, 0, nil), fake, nil)

	if err := manager.Busy("codex", "", time.Minute); err == nil {
		t.Fatal("Busy succeeded despite inhibitor error")
	}
	fake.SetAcquireError(nil)
	if err := manager.Reconcile(); err != nil {
		t.Fatalf("retry Reconcile: %v", err)
	}
	if !fake.Active() || fake.AcquireCalls() != 2 {
		t.Fatalf("acquire was not retried: active=%v calls=%d", fake.Active(), fake.AcquireCalls())
	}
}

func TestManagerRunExpiresWithoutIdleOrStatusRequest(t *testing.T) {
	clock := &fakeClock{}
	fake := &inhibit.Fake{}
	manager := NewManager(NewRegistry(clock, 0, nil), fake, nil)
	if err := manager.Busy("codex", "box-a", time.Second); err != nil {
		t.Fatalf("Busy: %v", err)
	}
	clock.Advance(time.Second)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		manager.Run(ctx, time.Millisecond, nil)
	}()
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	for fake.Active() {
		select {
		case <-deadline.C:
			cancel()
			<-done
			t.Fatal("background reconciliation did not release expired holder")
		default:
			time.Sleep(time.Millisecond)
		}
	}
	cancel()
	<-done
	if fake.ReleaseCalls() != 1 {
		t.Fatalf("release calls=%d, want 1", fake.ReleaseCalls())
	}
}

func TestManagerRunKeepsInhibitorDuringIdleGrace(t *testing.T) {
	clock := &fakeClock{}
	fake := &inhibit.Fake{}
	manager := NewManager(NewRegistry(clock, 2*time.Minute, nil), fake, nil)
	if err := manager.Busy("claude", "box-a", 15*time.Minute); err != nil {
		t.Fatalf("Busy: %v", err)
	}
	if err := manager.Idle("claude", "box-a"); err != nil {
		t.Fatalf("Idle: %v", err)
	}
	if !fake.Active() || fake.ReleaseCalls() != 0 {
		t.Fatalf("idle grace released inhibitor: active=%v calls=%d", fake.Active(), fake.ReleaseCalls())
	}
	clock.Advance(2 * time.Minute)

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() {
		defer close(done)
		manager.Run(ctx, time.Millisecond, nil)
	}()
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	for fake.Active() {
		select {
		case <-deadline.C:
			cancel()
			<-done
			t.Fatal("background reconciliation did not release lingered holder")
		default:
			time.Sleep(time.Millisecond)
		}
	}
	cancel()
	<-done
	if fake.ReleaseCalls() != 1 {
		t.Fatalf("release calls=%d, want 1", fake.ReleaseCalls())
	}
}

func TestManagerLogsInhibitorTransitions(t *testing.T) {
	var output bytes.Buffer
	logger := log.New(&output, "", 0)
	manager := NewManager(NewRegistry(&fakeClock{}, 0, nil), &inhibit.Fake{}, logger)
	if err := manager.Busy("claude", "box-a", time.Minute); err != nil {
		t.Fatalf("Busy: %v", err)
	}
	if err := manager.Idle("claude", "box-a"); err != nil {
		t.Fatalf("Idle: %v", err)
	}
	logs := output.String()
	for _, want := range []string{"sleep inhibitor acquired", "sleep inhibitor released"} {
		if !strings.Contains(logs, want) {
			t.Fatalf("logs %q do not contain %q", logs, want)
		}
	}
}

type assertionError string

func (e assertionError) Error() string { return string(e) }
