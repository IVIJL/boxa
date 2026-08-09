//go:build darwin

package powerwatch

import (
	"context"
	"log"
	"os/exec"
	"time"
)

func newPlatformSource() eventSource { return nil }

func newPlatformPrediction(hookRunner, time.Duration, *log.Logger, AwakeLeaseSource) *predictionWatch {
	return nil
}

func newPlatformSessionWatch(hookRunner, time.Duration, *log.Logger, *hookCoordinator) *sessionWatch {
	return nil
}

func newCommand(ctx context.Context, command string) (*exec.Cmd, error) {
	return exec.CommandContext(ctx, "sh", "-c", command), nil
}

func configureCommand(*exec.Cmd) {}
