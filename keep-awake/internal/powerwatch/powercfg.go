package powerwatch

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var currentPowerSettingPattern = regexp.MustCompile(`(?i)Current\s+(AC|DC)\s+Power\s+Setting\s+Index:\s*0x([0-9a-f]+)`)

type powercfgTimeouts struct {
	ac time.Duration
	dc time.Duration
}

func parsePowercfgTimeouts(output string) (powercfgTimeouts, error) {
	var result powercfgTimeouts
	found := 0
	for _, match := range currentPowerSettingPattern.FindAllStringSubmatch(output, -1) {
		seconds, err := strconv.ParseUint(match[2], 16, 32)
		if err != nil {
			return result, fmt.Errorf("parse powercfg %s timeout: %w", strings.ToUpper(match[1]), err)
		}
		timeout := time.Duration(seconds) * time.Second
		switch strings.ToUpper(match[1]) {
		case "AC":
			result.ac = timeout
			found |= 1
		case "DC":
			result.dc = timeout
			found |= 2
		}
	}
	if found != 3 {
		return result, fmt.Errorf("powercfg output did not contain current AC and DC sleep timeouts")
	}
	return result, nil
}
