//go:build darwin

package powerwatch

import (
	"context"
	"log"
	"os/exec"
	"time"
)

func newPlatformSource() eventSource { return nil }

func newPlatformSessionWatch(hookRunner, *WarmHook, time.Duration, *log.Logger) *sessionWatch {
	return nil
}

func warmHookSupported() bool { return false }

func newWarmHookCommand() (*exec.Cmd, error) { return nil, nil }

func newCommand(ctx context.Context, command string) (*exec.Cmd, error) {
	return exec.CommandContext(ctx, "sh", "-c", command), nil
}

func configureCommand(*exec.Cmd) {}
