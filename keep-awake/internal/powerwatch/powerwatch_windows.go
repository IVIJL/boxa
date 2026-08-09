//go:build windows

package powerwatch

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

const wslDistroEnvironment = "BOXA_WSL_DISTRO"

var (
	kernel32             = syscall.NewLazyDLL("kernel32.dll")
	user32               = syscall.NewLazyDLL("user32.dll")
	getLastInputInfo     = user32.NewProc("GetLastInputInfo")
	getSystemPowerStatus = kernel32.NewProc("GetSystemPowerStatus")
	getTickCount64       = kernel32.NewProc("GetTickCount64")
)

type lastInputInfo struct {
	Size uint32
	Time uint32
}

type systemPowerStatus struct {
	ACLineStatus        byte
	BatteryFlag         byte
	BatteryLifePercent  byte
	SystemStatusFlag    byte
	BatteryLifeTime     uint32
	BatteryFullLifeTime uint32
}

type windowsIdleSource struct{}

type powercfgSource struct {
	powerStatus func() (systemPowerStatus, error)
	runQuery    func(context.Context) ([]byte, error)
}

func newPlatformSource() eventSource { return nil }

func newPlatformPrediction(runner hookRunner, timeout time.Duration, logger *log.Logger, leases AwakeLeaseSource) *predictionWatch {
	settings := powercfgSource{powerStatus: readSystemPowerStatus, runQuery: queryPowercfg}
	return newPredictionWatch(windowsIdleSource{}, settings, realPredictionScheduler{}, runner, leases, timeout, logger)
}

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

func (windowsIdleSource) IdleTime() (time.Duration, error) {
	info := lastInputInfo{Size: uint32(unsafe.Sizeof(lastInputInfo{}))}
	ok, _, callErr := getLastInputInfo.Call(uintptr(unsafe.Pointer(&info)))
	if ok == 0 {
		if callErr != syscall.Errno(0) {
			return 0, fmt.Errorf("GetLastInputInfo: %w", callErr)
		}
		return 0, fmt.Errorf("GetLastInputInfo failed")
	}
	ticks, _, _ := getTickCount64.Call()
	idleMilliseconds := uint32(ticks) - info.Time
	return time.Duration(idleMilliseconds) * time.Millisecond, nil
}

func (s powercfgSource) SleepTimeout(ctx context.Context) (time.Duration, error) {
	status, err := s.powerStatus()
	if err != nil {
		return 0, err
	}
	output, err := s.runQuery(ctx)
	if err != nil {
		return 0, err
	}
	timeouts, err := parsePowercfgTimeouts(string(output))
	if err != nil {
		return 0, err
	}
	switch status.ACLineStatus {
	case 0:
		return timeouts.dc, nil
	case 1:
		return timeouts.ac, nil
	default:
		return 0, fmt.Errorf("GetSystemPowerStatus returned unknown AC line status %d", status.ACLineStatus)
	}
}

func readSystemPowerStatus() (systemPowerStatus, error) {
	var status systemPowerStatus
	ok, _, callErr := getSystemPowerStatus.Call(uintptr(unsafe.Pointer(&status)))
	if ok == 0 {
		if callErr != syscall.Errno(0) {
			return status, fmt.Errorf("GetSystemPowerStatus: %w", callErr)
		}
		return status, fmt.Errorf("GetSystemPowerStatus failed")
	}
	return status, nil
}

func queryPowercfg(ctx context.Context) ([]byte, error) {
	output, err := exec.CommandContext(ctx, "powercfg.exe", "/query", "SCHEME_CURRENT", "SUB_SLEEP", "STANDBYIDLE").CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("query powercfg sleep timeout: %w", err)
	}
	return output, nil
}
