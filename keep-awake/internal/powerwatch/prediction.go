package powerwatch

import (
	"context"
	"log"
	"time"
)

const (
	settingsRefreshInterval = 5 * time.Minute
	earlyCheckLead          = 2 * time.Minute
	finalCheckLead          = time.Minute
)

type idleTimeSource interface {
	IdleTime() (time.Duration, error)
}

type sleepTimeoutSource interface {
	SleepTimeout(context.Context) (time.Duration, error)
}

type predictionTimer interface {
	Chan() <-chan time.Time
	Stop()
}

type predictionScheduler interface {
	NewTimer(time.Duration) predictionTimer
}

type realPredictionScheduler struct{}

type realPredictionTimer struct {
	timer *time.Timer
}

func (realPredictionScheduler) NewTimer(delay time.Duration) predictionTimer {
	return &realPredictionTimer{timer: time.NewTimer(delay)}
}

func (t *realPredictionTimer) Chan() <-chan time.Time { return t.timer.C }
func (t *realPredictionTimer) Stop()                  { t.timer.Stop() }

type predictionWatch struct {
	idle            idleTimeSource
	settings        sleepTimeoutSource
	scheduler       predictionScheduler
	runner          hookRunner
	leases          AwakeLeaseSource
	hookTimeout     time.Duration
	refreshInterval time.Duration
	logger          *log.Logger

	timeout            time.Duration
	firedIdle          time.Duration
	waitingForActivity bool
	settingsFailed     bool
}

func newPredictionWatch(idle idleTimeSource, settings sleepTimeoutSource, scheduler predictionScheduler, runner hookRunner, leases AwakeLeaseSource, hookTimeout time.Duration, logger *log.Logger) *predictionWatch {
	return &predictionWatch{
		idle:            idle,
		settings:        settings,
		scheduler:       scheduler,
		runner:          runner,
		leases:          leases,
		hookTimeout:     hookTimeout,
		refreshInterval: settingsRefreshInterval,
		logger:          logger,
	}
}

func (w *predictionWatch) Run(ctx context.Context) error {
	var wakeTimer, refreshTimer predictionTimer
	defer stopPredictionTimer(&wakeTimer)
	defer stopPredictionTimer(&refreshTimer)

	leaseChanges := (<-chan struct{})(nil)
	if w.leases != nil {
		leaseChanges = w.leases.AwakeLeaseChanges()
	}

	reschedule := func() {
		stopPredictionTimer(&wakeTimer)
		stopPredictionTimer(&refreshTimer)
		if w.awakeLeaseHeld() {
			return
		}
		w.refresh(ctx)
		if w.awakeLeaseHeld() {
			return
		}
		refreshTimer = w.scheduler.NewTimer(w.refreshInterval)
		wakeTimer = w.nextTimer(ctx)
	}
	reschedule()

	for {
		var wake, refresh <-chan time.Time
		if wakeTimer != nil {
			wake = wakeTimer.Chan()
		}
		if refreshTimer != nil {
			refresh = refreshTimer.Chan()
		}
		select {
		case <-ctx.Done():
			return nil
		case <-leaseChanges:
			reschedule()
		case <-refresh:
			refreshTimer = nil
			reschedule()
		case <-wake:
			wakeTimer = nil
			wakeTimer = w.nextTimer(ctx)
		}
	}
}

func (w *predictionWatch) refresh(ctx context.Context) {
	timeout, err := w.settings.SleepTimeout(ctx)
	if err != nil {
		w.timeout = 0
		if !w.settingsFailed && w.logger != nil {
			w.logger.Printf("power-watch sleep settings unavailable: %v", err)
		}
		w.settingsFailed = true
		return
	}
	w.settingsFailed = false
	w.timeout = timeout
}

func (w *predictionWatch) nextTimer(ctx context.Context) predictionTimer {
	if w.timeout <= 0 || w.awakeLeaseHeld() {
		return nil
	}
	idle, err := w.idle.IdleTime()
	if err != nil {
		if w.logger != nil {
			w.logger.Printf("power-watch idle time unavailable: %v", err)
		}
		return nil
	}
	if w.waitingForActivity {
		if idle >= w.firedIdle {
			return nil
		}
		w.waitingForActivity = false
	}

	remaining := w.timeout - idle
	if remaining <= finalCheckLead {
		if !w.awakeLeaseHeld() {
			w.runHook(ctx, idle)
		}
		return nil
	}
	lead := earlyCheckLead
	if remaining <= earlyCheckLead {
		lead = finalCheckLead
	}
	return w.scheduler.NewTimer(remaining - lead)
}

func (w *predictionWatch) runHook(ctx context.Context, idle time.Duration) {
	if w.logger != nil {
		w.logger.Printf("power-watch predicts idle sleep within %s; running pre-sleep stop with %s budget", finalCheckLead, w.hookTimeout)
	}
	if err := w.runner.Run(ctx, w.hookTimeout); err != nil && w.logger != nil {
		w.logger.Printf("power-watch pre-sleep stop: %v", err)
	}
	w.firedIdle = idle
	w.waitingForActivity = true
}

func (w *predictionWatch) awakeLeaseHeld() bool {
	return w.leases != nil && w.leases.AwakeLeaseHeld()
}

func stopPredictionTimer(timer *predictionTimer) {
	if *timer == nil {
		return
	}
	(*timer).Stop()
	*timer = nil
}
