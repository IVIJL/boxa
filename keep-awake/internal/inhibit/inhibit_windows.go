//go:build windows

package inhibit

import "errors"

var errWindowsUnsupported = errors.New("Windows sleep inhibition not implemented (issue 09)")

type unsupportedInhibitor struct{}

// New returns a compile-only placeholder. Issue 09 will replace it with the
// Windows SetThreadExecutionState backend.
func New() Inhibitor { return unsupportedInhibitor{} }

func (unsupportedInhibitor) Acquire() error { return errWindowsUnsupported }
func (unsupportedInhibitor) Release() error { return nil }
func (unsupportedInhibitor) Active() bool   { return false }
func (unsupportedInhibitor) Close() error   { return nil }
