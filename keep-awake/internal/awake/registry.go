package awake

import (
	"errors"
	"log"
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
	mu             sync.Mutex
	clock          Clock
	idleGrace      time.Duration
	logger         *log.Logger
	expires        map[holderKey]time.Time
	lastRefreshLog map[holderKey]time.Time
}

func NewRegistry(clock Clock, idleGrace time.Duration, logger *log.Logger) *Registry {
	if clock == nil {
		clock = RealClock{}
	}
	return &Registry{
		clock: clock, idleGrace: idleGrace, logger: logger,
		expires:        make(map[holderKey]time.Time),
		lastRefreshLog: make(map[holderKey]time.Time),
	}
}

// Busy creates or re-arms a lease.
func (r *Registry) Busy(agent, session string, ttl time.Duration) error {
	return r.BusyFrom(agent, session, ttl, "")
}

// BusyFrom creates or re-arms a lease and records the heartbeat source for
// rate-limited refresh logging. The source does not affect holder identity.
func (r *Registry) BusyFrom(agent, session string, ttl time.Duration, source string) error {
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
	key := holderKey{agent: agent, session: session}
	_, existed := r.expires[key]
	r.expires[key] = now.Add(ttl)
	if !existed {
		r.lastRefreshLog[key] = now
		if r.logger != nil {
			r.logger.Printf("holder added: agent=%q session=%q ttl=%s", agent, session, ttl)
		}
	} else if !now.Before(r.lastRefreshLog[key].Add(5 * time.Minute)) {
		r.lastRefreshLog[key] = now
		if r.logger != nil {
			if source != "" {
				r.logger.Printf("holder refreshed: agent=%q session=%q src=%q ttl=%s", agent, session, source, ttl)
			} else {
				r.logger.Printf("holder refreshed: agent=%q session=%q ttl=%s", agent, session, ttl)
			}
		}
	}
	return nil
}

// Idle moves exactly one agent/session lease into its grace period. With a zero
// grace it releases the lease immediately. An absent lease remains absent.
func (r *Registry) Idle(agent, session string) bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	now := r.clock.Now()
	r.pruneLocked(now)
	key := holderKey{agent: agent, session: session}
	_, existed := r.expires[key]
	if !existed {
		return false
	}
	if r.idleGrace > 0 {
		r.expires[key] = now.Add(r.idleGrace)
		if r.logger != nil {
			r.logger.Printf("holder idle linger: agent=%q session=%q grace=%s", agent, session, r.idleGrace)
		}
	} else {
		delete(r.expires, key)
		delete(r.lastRefreshLog, key)
		if r.logger != nil {
			r.logger.Printf("holder removed on idle: agent=%q session=%q", agent, session)
		}
	}
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
			delete(r.lastRefreshLog, key)
			if r.logger != nil {
				r.logger.Printf("holder expired: agent=%q session=%q", key.agent, key.session)
			}
		}
	}
}
