package awake

import (
	"sync"
	"testing"
	"time"
)

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (f *fakeClock) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}
func (f *fakeClock) Advance(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.now = f.now.Add(d)
}

func TestRegistryBusyRearmsAndExpiresLease(t *testing.T) {
	clock := &fakeClock{now: time.Date(2026, 7, 30, 12, 0, 0, 0, time.UTC)}
	registry := NewRegistry(clock)

	if err := registry.Busy("codex", "box-a", 10*time.Second); err != nil {
		t.Fatalf("Busy: %v", err)
	}
	clock.Advance(7 * time.Second)
	if err := registry.Busy("codex", "box-a", 10*time.Second); err != nil {
		t.Fatalf("heartbeat Busy: %v", err)
	}
	clock.Advance(9 * time.Second)
	holders := registry.Active()
	if len(holders) != 1 {
		t.Fatalf("got %d holders, want 1", len(holders))
	}
	if holders[0].Remaining != time.Second {
		t.Fatalf("remaining = %s, want 1s", holders[0].Remaining)
	}

	clock.Advance(time.Second)
	if holders := registry.Active(); len(holders) != 0 {
		t.Fatalf("expired holder remains: %+v", holders)
	}
}

func TestRegistrySessionsAreIndependent(t *testing.T) {
	clock := &fakeClock{now: time.Date(2026, 7, 30, 12, 0, 0, 0, time.UTC)}
	registry := NewRegistry(clock)
	for _, session := range []string{"box-b", "box-a", ""} {
		if err := registry.Busy("claude", session, time.Minute); err != nil {
			t.Fatalf("Busy(%q): %v", session, err)
		}
	}

	registry.Idle("claude", "box-a")
	holders := registry.Active()
	if len(holders) != 2 {
		t.Fatalf("got %d holders, want 2", len(holders))
	}
	if holders[0].Session != "" || holders[1].Session != "box-b" {
		t.Fatalf("unexpected holders after session idle: %+v", holders)
	}

	registry.Idle("claude", "")
	holders = registry.Active()
	if len(holders) != 1 || holders[0].Session != "box-b" {
		t.Fatalf("sessionless idle released a named session: %+v", holders)
	}
}

func TestRegistryRejectsInvalidLease(t *testing.T) {
	registry := NewRegistry(&fakeClock{})
	if err := registry.Busy("", "session", time.Second); err == nil {
		t.Fatal("empty agent was accepted")
	}
	if err := registry.Busy("codex", "session", 0); err == nil {
		t.Fatal("zero TTL was accepted")
	}
}
