package awake

import (
	"bytes"
	"log"
	"strings"
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
	registry := NewRegistry(clock, 0, nil)

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
	registry := NewRegistry(clock, 0, nil)
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
	registry := NewRegistry(&fakeClock{}, 0, nil)
	if err := registry.Busy("", "session", time.Second); err == nil {
		t.Fatal("empty agent was accepted")
	}
	if err := registry.Busy("codex", "session", 0); err == nil {
		t.Fatal("zero TTL was accepted")
	}
}

func TestRegistryIdleLingersThenExpires(t *testing.T) {
	clock := &fakeClock{now: time.Date(2026, 7, 30, 12, 0, 0, 0, time.UTC)}
	registry := NewRegistry(clock, 2*time.Minute, nil)
	if err := registry.Busy("claude", "box-a", 15*time.Minute); err != nil {
		t.Fatalf("Busy: %v", err)
	}
	if !registry.Idle("claude", "box-a") {
		t.Fatal("Idle reported an existing holder as absent")
	}
	holders := registry.Active()
	if len(holders) != 1 || holders[0].Remaining != 2*time.Minute {
		t.Fatalf("holders after idle = %+v, want one holder with 2m remaining", holders)
	}
	clock.Advance(2 * time.Minute)
	if holders := registry.Active(); len(holders) != 0 {
		t.Fatalf("holder remains after grace: %+v", holders)
	}
}

func TestRegistryZeroGraceIdleRemovesImmediately(t *testing.T) {
	registry := NewRegistry(&fakeClock{}, 0, nil)
	if err := registry.Busy("claude", "box-a", time.Minute); err != nil {
		t.Fatalf("Busy: %v", err)
	}
	registry.Idle("claude", "box-a")
	if holders := registry.Active(); len(holders) != 0 {
		t.Fatalf("holder remains after zero-grace idle: %+v", holders)
	}
}

func TestRegistryIdleAbsentHolderIsNoOp(t *testing.T) {
	registry := NewRegistry(&fakeClock{}, 2*time.Minute, nil)
	if registry.Idle("claude", "missing") {
		t.Fatal("Idle reported an absent holder as existing")
	}
	if holders := registry.Active(); len(holders) != 0 {
		t.Fatalf("Idle created a holder: %+v", holders)
	}
}

func TestRegistryBusyAfterLingerRearmsFullTTL(t *testing.T) {
	clock := &fakeClock{}
	registry := NewRegistry(clock, 2*time.Minute, nil)
	if err := registry.Busy("claude", "box-a", 15*time.Minute); err != nil {
		t.Fatalf("Busy: %v", err)
	}
	registry.Idle("claude", "box-a")
	clock.Advance(time.Minute)
	if err := registry.Busy("claude", "box-a", 15*time.Minute); err != nil {
		t.Fatalf("Busy after linger: %v", err)
	}
	holders := registry.Active()
	if len(holders) != 1 || holders[0].Remaining != 15*time.Minute {
		t.Fatalf("holders after rearm = %+v, want one holder with 15m remaining", holders)
	}
}

func TestRegistryLogsTransitionsAndRateLimitedRefreshes(t *testing.T) {
	clock := &fakeClock{}
	var output bytes.Buffer
	registry := NewRegistry(clock, time.Minute, log.New(&output, "", 0))
	if err := registry.Busy("claude", "box-a", 15*time.Minute); err != nil {
		t.Fatalf("Busy: %v", err)
	}
	clock.Advance(4*time.Minute + 59*time.Second)
	if err := registry.BusyFrom("claude", "box-a", 15*time.Minute, "hook"); err != nil {
		t.Fatalf("refresh Busy: %v", err)
	}
	clock.Advance(time.Second)
	if err := registry.BusyFrom("claude", "box-a", 15*time.Minute, "refresher-123"); err != nil {
		t.Fatalf("periodic refresh Busy: %v", err)
	}
	if err := registry.BusyFrom("claude", "box-a", 15*time.Minute, "hook"); err != nil {
		t.Fatalf("suppressed refresh Busy: %v", err)
	}
	registry.Idle("claude", "box-a")
	clock.Advance(time.Minute)
	registry.Active()
	zeroGrace := NewRegistry(clock, 0, log.New(&output, "", 0))
	if err := zeroGrace.Busy("codex", "box-b", time.Minute); err != nil {
		t.Fatalf("zero-grace Busy: %v", err)
	}
	zeroGrace.Idle("codex", "box-b")

	logs := output.String()
	for _, want := range []string{
		`holder added: agent="claude" session="box-a" ttl=15m0s`,
		`holder refreshed: agent="claude" session="box-a" src="refresher-123" ttl=15m0s`,
		`holder idle linger: agent="claude" session="box-a" grace=1m0s`,
		`holder expired: agent="claude" session="box-a"`,
		`holder removed on idle: agent="codex" session="box-b"`,
	} {
		if !strings.Contains(logs, want) {
			t.Fatalf("logs %q do not contain %q", logs, want)
		}
	}
	if strings.Count(logs, `holder refreshed: agent="claude"`) != 1 {
		t.Fatalf("refresh log was not rate limited: %q", logs)
	}
}
