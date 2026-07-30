package awake

import (
	"errors"
	"sort"
	"sync"
	"time"
)

// Clock supplies the current time. Tests can replace it with a controllable
// clock without making the registry itself aware of timers or goroutines.
type Clock interface {
	Now() time.Time
}

// RealClock reads the system clock.
type RealClock struct{}

func (RealClock) Now() time.Time { return time.Now() }

// Holder identifies one independent keep-awake lease.
type Holder struct {
	Agent     string
	Session   string
	ExpiresAt time.Time
	Remaining time.Duration
}

type holderKey struct {
	agent   string
	session string
}

// Registry stores keep-awake leases in memory and prunes expired leases on
// every read or mutation.
type Registry struct {
	mu      sync.Mutex
	clock   Clock
	expires map[holderKey]time.Time
}

func NewRegistry(clock Clock) *Registry {
	if clock == nil {
		clock = RealClock{}
	}
	return &Registry{clock: clock, expires: make(map[holderKey]time.Time)}
}

// Busy creates or re-arms a lease.
func (r *Registry) Busy(agent, session string, ttl time.Duration) error {
	if agent == "" {
		return errors.New("agent must not be empty")
	}
	if ttl <= 0 {
		return errors.New("TTL must be positive")
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.clock.Now()
	r.pruneLocked(now)
	r.expires[holderKey{agent: agent, session: session}] = now.Add(ttl)
	return nil
}

// Idle releases exactly one agent/session lease. An empty session identifies
// the agent's sessionless lease; it never releases named concurrent sessions.
func (r *Registry) Idle(agent, session string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pruneLocked(r.clock.Now())
	key := holderKey{agent: agent, session: session}
	_, existed := r.expires[key]
	delete(r.expires, key)
	return existed
}

// Active returns a stable snapshot sorted by agent and then session.
func (r *Registry) Active() []Holder {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.clock.Now()
	r.pruneLocked(now)

	holders := make([]Holder, 0, len(r.expires))
	for key, expiry := range r.expires {
		holders = append(holders, Holder{
			Agent:     key.agent,
			Session:   key.session,
			ExpiresAt: expiry,
			Remaining: expiry.Sub(now),
		})
	}
	sort.Slice(holders, func(i, j int) bool {
		if holders[i].Agent == holders[j].Agent {
			return holders[i].Session < holders[j].Session
		}
		return holders[i].Agent < holders[j].Agent
	})
	return holders
}

func (r *Registry) pruneLocked(now time.Time) {
	for key, expiry := range r.expires {
		if !expiry.After(now) {
			delete(r.expires, key)
		}
	}
}
