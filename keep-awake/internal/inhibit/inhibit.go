package inhibit

// Inhibitor owns the operating-system resource that prevents system sleep.
// Implementations must make Acquire, Release, and Close idempotent.
type Inhibitor interface {
	Acquire() error
	Release() error
	Active() bool
	Close() error
}
