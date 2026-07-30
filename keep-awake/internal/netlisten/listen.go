package netlisten

import (
	"errors"
	"fmt"
	"net"
	"strconv"
)

var defaultAddresses = []string{"127.0.0.1"}

type ListenFunc func(network, address string) (net.Listener, error)

// Addresses combines the safe loopback default with explicitly configured IP
// addresses. Unspecified wildcard addresses are always rejected.
func Addresses(extra []string) ([]string, error) {
	all := append(append([]string(nil), defaultAddresses...), extra...)
	seen := make(map[string]bool, len(all))
	result := make([]string, 0, len(all))
	for _, address := range all {
		ip := net.ParseIP(address)
		if ip == nil {
			return nil, fmt.Errorf("listen address %q must be an IP address", address)
		}
		if ip.IsUnspecified() {
			return nil, fmt.Errorf("listen address %q is a wildcard and is not allowed", address)
		}
		canonical := ip.String()
		if !seen[canonical] {
			seen[canonical] = true
			result = append(result, canonical)
		}
	}
	return result, nil
}

// Open binds every configured address or closes all partial listeners on
// failure. Binding is also the daemon's single-instance guard.
func Open(addresses []string, port int, listen ListenFunc) ([]net.Listener, error) {
	if port < 0 || port > 65535 {
		return nil, fmt.Errorf("invalid port %d", port)
	}
	if listen == nil {
		listen = net.Listen
	}
	listeners := make([]net.Listener, 0, len(addresses))
	for _, address := range addresses {
		ip := net.ParseIP(address)
		if ip == nil || ip.IsUnspecified() {
			for _, opened := range listeners {
				_ = opened.Close()
			}
			return nil, fmt.Errorf("unsafe listen address %q", address)
		}
		endpoint := net.JoinHostPort(address, strconv.Itoa(port))
		listener, err := listen("tcp", endpoint)
		if err != nil {
			for _, opened := range listeners {
				_ = opened.Close()
			}
			return nil, fmt.Errorf("bind %s: %w", endpoint, err)
		}
		listeners = append(listeners, listener)
	}
	if len(listeners) == 0 {
		return nil, errors.New("no listen addresses configured")
	}
	return listeners, nil
}
