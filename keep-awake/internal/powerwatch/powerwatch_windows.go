//go:build windows

package powerwatch

import "os/exec"

func newPlatformSource() eventSource { return nil }

func configureCommand(*exec.Cmd) {}
