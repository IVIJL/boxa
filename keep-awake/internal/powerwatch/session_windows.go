//go:build windows

package powerwatch

import (
	"context"
	"fmt"
	"log"
	"os"
	"runtime"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

const (
	wmDestroy         = 0x0002
	wmClose           = 0x0010
	wmQueryEndSession = 0x0011
	wmEndSession      = 0x0016
)

var (
	getModuleHandleW             = kernel32.NewProc("GetModuleHandleW")
	registerClassExW             = user32.NewProc("RegisterClassExW")
	unregisterClassW             = user32.NewProc("UnregisterClassW")
	createWindowExW              = user32.NewProc("CreateWindowExW")
	destroyWindow                = user32.NewProc("DestroyWindow")
	defWindowProcW               = user32.NewProc("DefWindowProcW")
	getMessageW                  = user32.NewProc("GetMessageW")
	translateMessage             = user32.NewProc("TranslateMessage")
	dispatchMessageW             = user32.NewProc("DispatchMessageW")
	postMessageW                 = user32.NewProc("PostMessageW")
	postQuitMessage              = user32.NewProc("PostQuitMessage")
	shutdownBlockReasonCreate    = user32.NewProc("ShutdownBlockReasonCreate")
	shutdownBlockReasonDestroy   = user32.NewProc("ShutdownBlockReasonDestroy")
	windowsWindowProcCallback    = syscall.NewCallback(windowsWindowProc)
	windowsSessionSourceByWindow sync.Map
)

type windowsPoint struct {
	X int32
	Y int32
}

type windowsMessage struct {
	Window  uintptr
	Message uint32
	WParam  uintptr
	LParam  uintptr
	Time    uint32
	Point   windowsPoint
	Private uint32
}

type windowsClass struct {
	Size        uint32
	Style       uint32
	WindowProc  uintptr
	ClassExtra  int32
	WindowExtra int32
	Instance    uintptr
	Icon        uintptr
	Cursor      uintptr
	Background  uintptr
	MenuName    *uint16
	ClassName   *uint16
	IconSmall   uintptr
}

type windowsSessionSource struct {
	window  uintptr
	handle  func(sessionEvent)
	blocked bool
}

func newPlatformSessionWatch(runner hookRunner, timeout time.Duration, logger *log.Logger) *sessionWatch {
	return newSessionWatch(&windowsSessionSource{}, runner, timeout, logger)
}

func (s *windowsSessionSource) Run(ctx context.Context, handle func(sessionEvent)) (runErr error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	s.handle = handle

	instance, _, callErr := getModuleHandleW.Call(0)
	if instance == 0 {
		return windowsCallError("GetModuleHandleW", callErr)
	}
	className, err := syscall.UTF16PtrFromString(fmt.Sprintf("BoxaKeepAwakePowerWatch-%d", os.Getpid()))
	if err != nil {
		return fmt.Errorf("encode power-watch window class: %w", err)
	}
	class := windowsClass{
		Size:       uint32(unsafe.Sizeof(windowsClass{})),
		WindowProc: windowsWindowProcCallback,
		Instance:   instance,
		ClassName:  className,
	}
	atom, _, callErr := registerClassExW.Call(uintptr(unsafe.Pointer(&class)))
	if atom == 0 {
		return windowsCallError("RegisterClassExW", callErr)
	}
	defer func() {
		if result, _, unregisterErr := unregisterClassW.Call(uintptr(unsafe.Pointer(className)), instance); result == 0 && runErr == nil {
			runErr = windowsCallError("UnregisterClassW", unregisterErr)
		}
	}()

	windowName, err := syscall.UTF16PtrFromString("Boxa power-watch")
	if err != nil {
		return fmt.Errorf("encode power-watch window name: %w", err)
	}
	window, _, callErr := createWindowExW.Call(
		0,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(windowName)),
		0,
		0, 0, 0, 0,
		0, 0, instance, 0,
	)
	if window == 0 {
		return windowsCallError("CreateWindowExW", callErr)
	}
	s.window = window
	windowsSessionSourceByWindow.Store(window, s)
	defer func() {
		windowsSessionSourceByWindow.Delete(window)
		s.window = 0
	}()

	pumpDone := make(chan struct{})
	defer close(pumpDone)
	go func() {
		select {
		case <-ctx.Done():
			postMessageW.Call(window, wmClose, 0, 0)
		case <-pumpDone:
		}
	}()

	var message windowsMessage
	for {
		result, _, messageErr := getMessageW.Call(uintptr(unsafe.Pointer(&message)), 0, 0, 0)
		if int32(result) == -1 {
			destroyWindow.Call(window)
			return windowsCallError("GetMessageW", messageErr)
		}
		if result == 0 {
			return nil
		}
		translateMessage.Call(uintptr(unsafe.Pointer(&message)))
		dispatchMessageW.Call(uintptr(unsafe.Pointer(&message)))
	}
}

func (s *windowsSessionSource) CreateShutdownBlockReason() error {
	reason, err := syscall.UTF16PtrFromString("Stopping boxa containers…")
	if err != nil {
		return err
	}
	result, _, callErr := shutdownBlockReasonCreate.Call(s.window, uintptr(unsafe.Pointer(reason)))
	if result == 0 {
		return windowsCallError("ShutdownBlockReasonCreate", callErr)
	}
	s.blocked = true
	return nil
}

func (s *windowsSessionSource) DestroyShutdownBlockReason() error {
	if !s.blocked {
		return nil
	}
	result, _, callErr := shutdownBlockReasonDestroy.Call(s.window)
	if result == 0 {
		return windowsCallError("ShutdownBlockReasonDestroy", callErr)
	}
	s.blocked = false
	return nil
}

func windowsWindowProc(window uintptr, message uint32, wParam, lParam uintptr) uintptr {
	value, found := windowsSessionSourceByWindow.Load(window)
	if found {
		source := value.(*windowsSessionSource)
		switch message {
		case wmQueryEndSession:
			source.handle(sessionShutdownQuery)
			return 1
		case wmEndSession:
			if wParam != 0 {
				source.handle(sessionShutdownEnd)
			} else {
				source.handle(sessionShutdownCancelled)
			}
			return 0
		case wmClose:
			destroyWindow.Call(window)
			return 0
		case wmDestroy:
			postQuitMessage.Call(0)
			return 0
		}
	}
	result, _, _ := defWindowProcW.Call(window, uintptr(message), wParam, lParam)
	return result
}

func windowsCallError(name string, callErr error) error {
	if callErr != syscall.Errno(0) {
		return fmt.Errorf("%s: %w", name, callErr)
	}
	return fmt.Errorf("%s failed", name)
}
