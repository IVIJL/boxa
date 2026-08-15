package httpapi

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/IVIJL/boxa/keep-awake/internal/awake"
	"github.com/IVIJL/boxa/keep-awake/internal/inhibit"
	"github.com/IVIJL/boxa/keep-awake/internal/powerwatch"
)

type fakeClock struct {
	mu  sync.Mutex
	now time.Time
}

func (f *fakeClock) Now() time.Time {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.now
}
func (f *fakeClock) Advance(d time.Duration) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.now = f.now.Add(d)
}

type decodedStatus struct {
	ActiveHolders []struct {
		Agent               string `json:"agent"`
		Session             string `json:"session"`
		RemainingTTLSeconds int64  `json:"remainingTTLSeconds"`
	} `json:"activeHolders"`
	IsInhibited bool `json:"isInhibited"`
	PowerWatch  struct {
		Active                 bool   `json:"active"`
		StopBudgetSeconds      int64  `json:"stopBudgetSeconds"`
		InhibitDelayMaxSeconds int64  `json:"inhibitDelayMaxSeconds"`
		Hint                   string `json:"hint"`
		WarmHookArmed          bool   `json:"warmHookArmed"`
		WarmHookAlive          bool   `json:"warmHookAlive"`
	} `json:"powerWatch"`
	Version string `json:"version"`
}

type fakeWarmHook struct {
	mu          sync.Mutex
	armCalls    int
	disarmCalls int
}

func (f *fakeWarmHook) Arm() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.armCalls++
}
func (f *fakeWarmHook) Disarm() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.disarmCalls++
}
func (f *fakeWarmHook) calls() (int, int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.armCalls, f.disarmCalls
}

type blockingWarmHook struct {
	started chan struct{}
	release chan struct{}
}

func (h *blockingWarmHook) Arm() {}
func (h *blockingWarmHook) Disarm() {
	close(h.started)
	<-h.release
}

func newTestAPI() (*API, *fakeClock, *inhibit.Fake) {
	clock := &fakeClock{now: time.Date(2026, 7, 30, 12, 0, 0, 0, time.UTC)}
	fake := &inhibit.Fake{}
	manager := awake.NewManager(awake.NewRegistry(clock), fake)
	powerStatus := func() powerwatch.Status {
		return powerwatch.Status{
			Active:          true,
			StopBudget:      time.Minute,
			InhibitDelayMax: 5 * time.Second,
			Hint:            "raise InhibitDelayMaxSec in logind.conf",
			WarmHookArmed:   true,
			WarmHookAlive:   true,
		}
	}
	return New(manager, powerStatus, &fakeWarmHook{}, 15*time.Minute, "test-version", nil), clock, fake
}

func request(t *testing.T, handler http.Handler, method, target string) *httptest.ResponseRecorder {
	t.Helper()
	recorder := httptest.NewRecorder()
	handler.ServeHTTP(recorder, httptest.NewRequest(method, target, nil))
	return recorder
}

func getStatus(t *testing.T, api *API) decodedStatus {
	t.Helper()
	response := request(t, api, http.MethodGet, "/v1/status")
	if response.Code != http.StatusOK {
		t.Fatalf("status code = %d, body=%s", response.Code, response.Body.String())
	}
	var status decodedStatus
	if err := json.Unmarshal(response.Body.Bytes(), &status); err != nil {
		t.Fatalf("decode status: %v", err)
	}
	return status
}

func TestBusyStatusAndTTLExpiry(t *testing.T) {
	api, clock, fake := newTestAPI()
	response := request(t, api, http.MethodGet, "/v1/busy/codex?ttl=10&session=box-a")
	if response.Code != http.StatusOK {
		t.Fatalf("busy code = %d, body=%s", response.Code, response.Body.String())
	}
	status := getStatus(t, api)
	if !status.IsInhibited || status.Version != "test-version" || len(status.ActiveHolders) != 1 {
		t.Fatalf("unexpected busy status: %+v", status)
	}
	if !status.PowerWatch.Active || status.PowerWatch.StopBudgetSeconds != 60 ||
		status.PowerWatch.InhibitDelayMaxSeconds != 5 || !status.PowerWatch.WarmHookArmed ||
		!status.PowerWatch.WarmHookAlive || !strings.Contains(status.PowerWatch.Hint, "InhibitDelayMaxSec") {
		t.Fatalf("unexpected power-watch status: %+v", status.PowerWatch)
	}
	holder := status.ActiveHolders[0]
	if holder.Agent != "codex" || holder.Session != "box-a" || holder.RemainingTTLSeconds != 10 {
		t.Fatalf("unexpected holder: %+v", holder)
	}

	clock.Advance(10 * time.Second)
	status = getStatus(t, api)
	if status.IsInhibited || len(status.ActiveHolders) != 0 || fake.ReleaseCalls() != 1 {
		t.Fatalf("expired status: %+v, release calls=%d", status, fake.ReleaseCalls())
	}
}

func TestWarmHookArmAndDisarm(t *testing.T) {
	api, _, _ := newTestAPI()
	warmHook := api.warmHook.(*fakeWarmHook)

	for _, body := range []string{`{"armed":true}`, `{"armed":false}`} {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, warmHookPath, strings.NewReader(body))
		api.ServeHTTP(recorder, request)
		if recorder.Code != http.StatusOK {
			t.Fatalf("body=%s code=%d response=%s", body, recorder.Code, recorder.Body.String())
		}
	}
	deadline := time.Now().Add(time.Second)
	for {
		armCalls, disarmCalls := warmHook.calls()
		if armCalls == 1 && disarmCalls == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("warm-hook calls: arm=%d disarm=%d", armCalls, disarmCalls)
		}
		time.Sleep(time.Millisecond)
	}
}

func TestWarmHookDisarmRespondsWithoutWaiting(t *testing.T) {
	api, _, _ := newTestAPI()
	warmHook := &blockingWarmHook{started: make(chan struct{}), release: make(chan struct{})}
	api.warmHook = warmHook
	done := make(chan *httptest.ResponseRecorder, 1)
	go func() {
		recorder := httptest.NewRecorder()
		request := httptest.NewRequest(http.MethodPost, warmHookPath, strings.NewReader(`{"armed":false}`))
		api.ServeHTTP(recorder, request)
		done <- recorder
	}()

	select {
	case <-warmHook.started:
	case <-time.After(time.Second):
		t.Fatal("warm-hook disarm did not start")
	}
	select {
	case recorder := <-done:
		if recorder.Code != http.StatusOK {
			t.Fatalf("code=%d response=%s", recorder.Code, recorder.Body.String())
		}
	case <-time.After(100 * time.Millisecond):
		close(warmHook.release)
		t.Fatal("warm-hook disarm blocked the HTTP response")
	}
	close(warmHook.release)
}

func TestIdleOnlyReleasesMatchingSession(t *testing.T) {
	api, _, fake := newTestAPI()
	for _, target := range []string{
		"/v1/busy/claude?session=box-a",
		"/v1/busy/claude?session=box-b",
	} {
		if response := request(t, api, http.MethodGet, target); response.Code != http.StatusOK {
			t.Fatalf("%s code=%d body=%s", target, response.Code, response.Body.String())
		}
	}
	response := request(t, api, http.MethodGet, "/v1/idle/claude?session=box-a")
	if response.Code != http.StatusOK {
		t.Fatalf("idle code=%d body=%s", response.Code, response.Body.String())
	}
	status := getStatus(t, api)
	if len(status.ActiveHolders) != 1 || status.ActiveHolders[0].Session != "box-b" {
		t.Fatalf("unexpected holders after idle: %+v", status.ActiveHolders)
	}
	if !status.IsInhibited || fake.ReleaseCalls() != 0 {
		t.Fatalf("inhibitor released too early: status=%+v calls=%d", status, fake.ReleaseCalls())
	}
}

func TestDefaultTTLAndHeartbeat(t *testing.T) {
	api, clock, fake := newTestAPI()
	if response := request(t, api, http.MethodGet, "/v1/busy/pi"); response.Code != http.StatusOK {
		t.Fatalf("first busy code=%d", response.Code)
	}
	clock.Advance(10 * time.Minute)
	if response := request(t, api, http.MethodGet, "/v1/busy/pi"); response.Code != http.StatusOK {
		t.Fatalf("heartbeat code=%d", response.Code)
	}
	status := getStatus(t, api)
	if status.ActiveHolders[0].RemainingTTLSeconds != 900 {
		t.Fatalf("remaining TTL=%d, want 900", status.ActiveHolders[0].RemainingTTLSeconds)
	}
	if fake.AcquireCalls() != 1 {
		t.Fatalf("heartbeat reacquired inhibitor; calls=%d", fake.AcquireCalls())
	}
}

func TestContractErrors(t *testing.T) {
	api, _, _ := newTestAPI()
	tests := []struct {
		method string
		target string
		code   int
		hint   string
	}{
		{http.MethodGet, "/status", http.StatusNotFound, "/v1/status"},
		{http.MethodGet, "/v2/status", http.StatusNotFound, "/v1/status"},
		{http.MethodPost, "/v1/status", http.StatusMethodNotAllowed, "use GET"},
		{http.MethodGet, warmHookPath, http.StatusMethodNotAllowed, "use POST"},
		{http.MethodGet, "/v1/busy/codex?ttl=0", http.StatusBadRequest, "positive integer"},
		{http.MethodGet, "/v1/busy/bad%2Fagent", http.StatusBadRequest, "agent"},
		{http.MethodGet, "/v1/busy/codex?session=bad%00session", http.StatusBadRequest, "session"},
	}
	for _, test := range tests {
		t.Run(test.method+" "+test.target, func(t *testing.T) {
			response := request(t, api, test.method, test.target)
			if response.Code != test.code || !strings.Contains(response.Body.String(), test.hint) {
				t.Fatalf("code=%d body=%q, want code=%d hint=%q", response.Code, response.Body.String(), test.code, test.hint)
			}
		})
	}
}
