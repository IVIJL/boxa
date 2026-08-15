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

func warmHookSupported() bool { return true }

func newWarmHookCommand() (*exec.Cmd, error) {
	distro, err := wslDistro()
	if err != nil {
		return nil, err
	}
	return exec.Command("wsl.exe", "-d", distro, "--", "boxa", "__keep-awake-stop-wait"), nil
}

func newCommand(ctx context.Context, command string) (*exec.Cmd, error) {
	if command != DefaultCommand {
		return exec.CommandContext(ctx, "cmd.exe", "/d", "/s", "/c", command), nil
	}
	distro, err := wslDistro()
	if err != nil {
		return nil, err
	}
	return exec.CommandContext(ctx, "wsl.exe", "-d", distro, "--", "boxa", "stop", "--all", "--reason", "presleep"), nil
}

func wslDistro() (string, error) {
	distro := strings.TrimSpace(os.Getenv(wslDistroEnvironment))
	if distro == "" {
		return "", fmt.Errorf("%s is not set; re-run boxa keep-awake enable", wslDistroEnvironment)
	}
	return distro, nil
}

func configureCommand(*exec.Cmd) {}
