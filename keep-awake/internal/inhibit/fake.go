package inhibit

import "sync"

// Fake is a deterministic inhibitor for tests.
type Fake struct {
	mu sync.Mutex

	active       bool
	acquireCalls int
	releaseCalls int
	acquireErr   error
	releaseErr   error
}

func (f *Fake) Acquire() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.active {
		return nil
	}
	f.acquireCalls++
	if f.acquireErr != nil {
		return f.acquireErr
	}
	f.active = true
	return nil
}

func (f *Fake) Release() error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if !f.active {
		return nil
	}
	f.releaseCalls++
	if f.releaseErr != nil {
		return f.releaseErr
	}
	f.active = false
	return nil
}

func (f *Fake) Active() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.active
}

func (f *Fake) Close() error { return f.Release() }

func (f *Fake) AcquireCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.acquireCalls
}

func (f *Fake) ReleaseCalls() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.releaseCalls
}

func (f *Fake) SetAcquireError(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.acquireErr = err
}

func (f *Fake) SetReleaseError(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.releaseErr = err
}
