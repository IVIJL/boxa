//go:build windows

package powerwatch

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"
)

const wslDistroEnvironment = "BOXA_WSL_DISTRO"

var (
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	user32   = syscall.NewLazyDLL("user32.dll")
)

func newPlatformSource() eventSource { return nil }

func newCommand(ctx context.Context, command string) (*exec.Cmd, error) {
	if command != DefaultCommand {
		return exec.CommandContext(ctx, "cmd.exe", "/d", "/s", "/c", command), nil
	}
	distro := strings.TrimSpace(os.Getenv(wslDistroEnvironment))
	if distro == "" {
		return nil, fmt.Errorf("%s is not set; re-run boxa keep-awake enable", wslDistroEnvironment)
	}
	return exec.CommandContext(ctx, "wsl.exe", "-d", distro, "--", "boxa", "stop", "--all", "--reason", "presleep"), nil
}

func configureCommand(*exec.Cmd) {}
