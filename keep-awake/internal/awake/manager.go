package awake

import (
	"context"
	"sync"
	"time"

	"github.com/IVIJL/boxa/keep-awake/internal/inhibit"
)

// Status is a consistent snapshot of holders and inhibitor state.
type Status struct {
	Holders   []Holder
	Inhibited bool
}

// Manager serializes holder mutations with inhibitor transitions.
type Manager struct {
	mu        sync.Mutex
	registry  *Registry
	inhibitor inhibit.Inhibitor
	leaseHeld bool
	changes   chan struct{}
}

func NewManager(registry *Registry, inhibitor inhibit.Inhibitor) *Manager {
	return &Manager{registry: registry, inhibitor: inhibitor, changes: make(chan struct{}, 1)}
}

func (m *Manager) Busy(agent, session string, ttl time.Duration) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if err := m.registry.Busy(agent, session, ttl); err != nil {
		return err
	}
	return m.reconcileLocked()
}

func (m *Manager) Idle(agent, session string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.registry.Idle(agent, session)
	return m.reconcileLocked()
}

// Reconcile prunes expired leases and makes the inhibitor match the resulting
// desired state. It is safe to call periodically and after every request.
func (m *Manager) Reconcile() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.reconcileLocked()
}

func (m *Manager) Status() (Status, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	holders := m.registry.Active()
	m.setLeaseHeldLocked(len(holders) > 0)
	err := m.setInhibitionLocked(len(holders) > 0)
	return Status{Holders: holders, Inhibited: m.inhibitor.Active()}, err
}

func (m *Manager) reconcileLocked() error {
	held := len(m.registry.Active()) > 0
	m.setLeaseHeldLocked(held)
	return m.setInhibitionLocked(held)
}

// AwakeLeaseHeld implements powerwatch.AwakeLeaseSource without coupling the
// awake package to powerwatch.
func (m *Manager) AwakeLeaseHeld() bool {
	m.mu.Lock()
	defer m.mu.Unlock()
	return len(m.registry.Active()) > 0
}

// AwakeLeaseChanges reports transitions between zero and non-zero holders.
func (m *Manager) AwakeLeaseChanges() <-chan struct{} { return m.changes }

func (m *Manager) setLeaseHeldLocked(held bool) {
	if held == m.leaseHeld {
		return
	}
	m.leaseHeld = held
	select {
	case m.changes <- struct{}{}:
	default:
	}
}

func (m *Manager) setInhibitionLocked(want bool) error {
	if want && !m.inhibitor.Active() {
		return m.inhibitor.Acquire()
	}
	if !want && m.inhibitor.Active() {
		return m.inhibitor.Release()
	}
	return nil
}

// Run periodically expires abandoned leases. Errors are reported and retried
// at the next tick so a temporary inhibitor failure does not stop the daemon.
func (m *Manager) Run(ctx context.Context, interval time.Duration, report func(error)) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if err := m.Reconcile(); err != nil && report != nil {
				report(err)
			}
		}
	}
}

func (m *Manager) Close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.inhibitor.Close()
}
