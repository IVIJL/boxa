package powerwatch

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestWarmHookArmsAndRespawnsWithBackoff(t *testing.T) {
	var mu sync.Mutex
	var spawns []time.Time
	command := func() (*exec.Cmd, error) {
		mu.Lock()
		spawns = append(spawns, time.Now())
		mu.Unlock()
		return warmHookStubCommand("exit", ""), nil
	}
	hook := newWarmHook(command, io.Discard, nil, 20*time.Millisecond, 40*time.Millisecond)
	hook.Arm()
	t.Cleanup(hook.Disarm)

	waitForWarmHook(t, func() bool {
		mu.Lock()
		defer mu.Unlock()
		return len(spawns) >= 3
	})
	hook.Disarm()

	mu.Lock()
	defer mu.Unlock()
	if first := spawns[1].Sub(spawns[0]); first < 15*time.Millisecond {
		t.Fatalf("first respawn delay = %s, want at least 15ms", first)
	}
	if second := spawns[2].Sub(spawns[1]); second < 35*time.Millisecond {
		t.Fatalf("second respawn delay = %s, want at least 35ms", second)
	}
}

func TestWarmHookNoBoxesSelfDisarms(t *testing.T) {
	var mu sync.Mutex
	spawns := 0
	command := func() (*exec.Cmd, error) {
		mu.Lock()
		spawns++
		mu.Unlock()
		return warmHookStubCommand("no-boxes", ""), nil
	}
	hook := newWarmHook(command, io.Discard, nil, 10*time.Millisecond, 20*time.Millisecond)
	hook.Arm()

	waitForWarmHook(t, func() bool {
		hook.mu.Lock()
		defer hook.mu.Unlock()
		return !hook.armed && hook.loopDone == nil
	})
	time.Sleep(30 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if spawns != 1 {
		t.Fatalf("warm-hook spawns = %d, want 1 after no-boxes", spawns)
	}
}

func TestWarmHookDisarmClosesPipeAndReapsChild(t *testing.T) {
	eofFile := t.TempDir() + "/eof"
	hook := newWarmHook(
		func() (*exec.Cmd, error) { return warmHookStubCommand("wait-eof", eofFile), nil },
		io.Discard,
		nil,
		10*time.Millisecond,
		20*time.Millisecond,
	)
	hook.Arm()
	waitWarmHookAlive(t, hook)
	if armed, alive := hook.Status(); !armed || !alive {
		t.Fatalf("warm-hook status before disarm = armed:%t alive:%t", armed, alive)
	}
	hook.Disarm()
	if armed, alive := hook.Status(); armed || alive {
		t.Fatalf("warm-hook status after disarm = armed:%t alive:%t", armed, alive)
	}

	data, err := os.ReadFile(eofFile)
	if err != nil {
		t.Fatalf("read EOF marker: %v", err)
	}
	if string(data) != "eof\n" {
		t.Fatalf("EOF marker = %q, want %q", data, "eof\n")
	}
	hook.mu.Lock()
	defer hook.mu.Unlock()
	if hook.child != nil || hook.loopDone != nil {
		t.Fatal("warm-hook child was not reaped on disarm")
	}
}

func TestWindowsShutdownUsesWarmHookAndWaitsForDone(t *testing.T) {
	stopFile := t.TempDir() + "/stop"
	hook := newWarmHook(
		func() (*exec.Cmd, error) { return warmHookStubCommand("wait-stop", stopFile), nil },
		io.Discard,
		nil,
		10*time.Millisecond,
		20*time.Millisecond,
	)
	hook.Arm()
	t.Cleanup(hook.Disarm)
	waitWarmHookAlive(t, hook)

	source := newFakeSessionSource()
	runner := &fakeRunner{}
	watch := newSessionWatch(source, runner, hook, time.Second, nil)
	watch.handleShutdown(context.Background())

	data, err := os.ReadFile(stopFile)
	if err != nil {
		t.Fatalf("read stop marker: %v", err)
	}
	if string(data) != "stop\n" {
		t.Fatalf("warm-hook input = %q, want %q", data, "stop\n")
	}
	if runner.CallCount() != 0 {
		t.Fatalf("fallback calls = %d, want 0", runner.CallCount())
	}
}

func TestWindowsShutdownLogsAndFallsBackWhenWarmHookIsDown(t *testing.T) {
	var output bytes.Buffer
	runner := &fakeRunner{}
	watch := newSessionWatch(
		newFakeSessionSource(),
		runner,
		newWarmHook(func() (*exec.Cmd, error) { return nil, nil }, io.Discard, nil, time.Second, time.Second),
		time.Second,
		log.New(&output, "", 0),
	)

	watch.handleShutdown(context.Background())
	if runner.CallCount() != 1 {
		t.Fatalf("fallback calls = %d, want 1", runner.CallCount())
	}
	if !strings.Contains(output.String(), "warm hook was down") {
		t.Fatalf("log = %q, want warm-hook fallback message", output.String())
	}
}

func waitWarmHookAlive(t *testing.T, hook *WarmHook) {
	t.Helper()
	waitForWarmHook(t, func() bool {
		hook.mu.Lock()
		defer hook.mu.Unlock()
		return hook.alive
	})
}

func waitForWarmHook(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatal("timed out waiting for warm hook")
		}
		time.Sleep(time.Millisecond)
	}
}

func warmHookStubCommand(mode, marker string) *exec.Cmd {
	cmd := exec.Command(os.Args[0], "-test.run=^TestWarmHookStubProcess$")
	cmd.Env = append(os.Environ(),
		"GO_WANT_WARM_HOOK_STUB=1",
		"WARM_HOOK_STUB_MODE="+mode,
		"WARM_HOOK_STUB_MARKER="+marker,
	)
	return cmd
}

func TestWarmHookStubProcess(t *testing.T) {
	if os.Getenv("GO_WANT_WARM_HOOK_STUB") != "1" {
		return
	}

	switch os.Getenv("WARM_HOOK_STUB_MODE") {
	case "exit":
		os.Exit(1)
	case "no-boxes":
		fmt.Println("no-boxes")
		return
	case "wait-eof":
		fmt.Println("ready")
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
		}
		writeWarmHookStubMarker("eof")
	case "wait-stop":
		fmt.Println("ready")
		scanner := bufio.NewScanner(os.Stdin)
		if scanner.Scan() {
			writeWarmHookStubMarker(scanner.Text())
			fmt.Println("done")
		}
	default:
		code, _ := strconv.Atoi(os.Getenv("WARM_HOOK_STUB_MODE"))
		os.Exit(code)
	}
}

func writeWarmHookStubMarker(value string) {
	file, err := os.OpenFile(os.Getenv("WARM_HOOK_STUB_MARKER"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		os.Exit(2)
	}
	defer file.Close()
	if _, err := fmt.Fprintln(file, value); err != nil {
		os.Exit(2)
	}
}
