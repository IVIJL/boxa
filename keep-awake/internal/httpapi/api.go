package httpapi

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"strconv"
	"strings"
	"time"
	"unicode"

	"github.com/IVIJL/boxa/keep-awake/internal/awake"
)

const statusPath = "/v1/status"

type API struct {
	manager    *awake.Manager
	defaultTTL time.Duration
	version    string
	logger     *log.Logger
}

func New(manager *awake.Manager, defaultTTL time.Duration, version string, logger *log.Logger) *API {
	return &API{manager: manager, defaultTTL: defaultTTL, version: version, logger: logger}
}

type holderResponse struct {
	Agent               string `json:"agent"`
	Session             string `json:"session,omitempty"`
	RemainingTTLSeconds int64  `json:"remainingTTLSeconds"`
}

type statusResponse struct {
	ActiveHolders []holderResponse `json:"activeHolders"`
	IsInhibited   bool             `json:"isInhibited"`
	Version       string           `json:"version"`
}

func (a *API) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == statusPath:
		a.status(w, r)
	case strings.HasPrefix(r.URL.Path, "/v1/busy/"):
		a.busy(w, r, strings.TrimPrefix(r.URL.Path, "/v1/busy/"))
	case strings.HasPrefix(r.URL.Path, "/v1/idle/"):
		a.idle(w, r, strings.TrimPrefix(r.URL.Path, "/v1/idle/"))
	default:
		writeError(w, http.StatusNotFound, "unknown path; see "+statusPath)
	}
}

func (a *API) status(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	status, err := a.manager.Status()
	if err != nil && a.logger != nil {
		a.logger.Printf("reconcile inhibitor while serving status: %v", err)
	}
	holders := make([]holderResponse, 0, len(status.Holders))
	for _, holder := range status.Holders {
		remainingSeconds := int64((holder.Remaining + time.Second - 1) / time.Second)
		holders = append(holders, holderResponse{
			Agent:               holder.Agent,
			Session:             holder.Session,
			RemainingTTLSeconds: remainingSeconds,
		})
	}
	writeJSON(w, http.StatusOK, statusResponse{
		ActiveHolders: holders,
		IsInhibited:   status.Inhibited,
		Version:       a.version,
	})
}

func (a *API) busy(w http.ResponseWriter, r *http.Request, agent string) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	session, ok := validateIdentity(w, agent, r.URL.Query().Get("session"))
	if !ok {
		return
	}
	ttl := a.defaultTTL
	if raw := r.URL.Query().Get("ttl"); raw != "" {
		seconds, err := strconv.ParseInt(raw, 10, 32)
		if err != nil || seconds <= 0 {
			writeError(w, http.StatusBadRequest, "ttl must be a positive integer number of seconds")
			return
		}
		ttl = time.Duration(seconds) * time.Second
	}
	if err := a.manager.Busy(agent, session, ttl); err != nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Sprintf("sleep inhibitor unavailable: %v", err))
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (a *API) idle(w http.ResponseWriter, r *http.Request, agent string) {
	if r.Method != http.MethodGet {
		methodNotAllowed(w)
		return
	}
	session, ok := validateIdentity(w, agent, r.URL.Query().Get("session"))
	if !ok {
		return
	}
	if err := a.manager.Idle(agent, session); err != nil {
		writeError(w, http.StatusServiceUnavailable, fmt.Sprintf("sleep inhibitor release failed: %v", err))
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func validateIdentity(w http.ResponseWriter, agent, session string) (string, bool) {
	if !validAgent(agent) {
		writeError(w, http.StatusBadRequest, "agent must be a non-empty path segment of at most 128 characters")
		return "", false
	}
	if !validSession(session) {
		writeError(w, http.StatusBadRequest, "session must be at most 256 characters and contain no control characters")
		return "", false
	}
	return session, true
}

func validAgent(value string) bool {
	if value == "" || len([]rune(value)) > 128 || strings.Contains(value, "/") {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func validSession(value string) bool {
	if len([]rune(value)) > 256 {
		return false
	}
	for _, r := range value {
		if unicode.IsControl(r) {
			return false
		}
	}
	return true
}

func methodNotAllowed(w http.ResponseWriter) {
	w.Header().Set("Allow", http.MethodGet)
	writeError(w, http.StatusMethodNotAllowed, "method not allowed; use GET")
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
