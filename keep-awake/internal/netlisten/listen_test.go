package netlisten

import (
	"errors"
	"net"
	"strconv"
	"strings"
	"testing"
)

func TestAddressesAllowLoopbackWithoutUnsafeOptIn(t *testing.T) {
	addresses, err := Addresses([]string{"127.0.0.1", "::1"}, false)
	if err != nil {
		t.Fatalf("Addresses: %v", err)
	}
	want := []string{"127.0.0.1", "::1"}
	if strings.Join(addresses, ",") != strings.Join(want, ",") {
		t.Fatalf("addresses=%v, want %v", addresses, want)
	}
	if _, err := Addresses([]string{"192.168.65.1"}, false); err == nil || !strings.Contains(err.Error(), "-listen-unsafe") {
		t.Fatalf("non-loopback address did not require -listen-unsafe: %v", err)
	}
}

func TestAddressesAllowSpecificNonLoopbackWithUnsafeOptIn(t *testing.T) {
	addresses, err := Addresses([]string{"192.168.65.1"}, true)
	if err != nil {
		t.Fatalf("Addresses: %v", err)
	}
	want := []string{"127.0.0.1", "192.168.65.1"}
	if strings.Join(addresses, ",") != strings.Join(want, ",") {
		t.Fatalf("addresses=%v, want %v", addresses, want)
	}
}

func TestAddressesNeverAllowWildcardOrHostname(t *testing.T) {
	for _, wildcard := range []string{"0.0.0.0", "::"} {
		if _, err := Addresses([]string{wildcard}, true); err == nil {
			t.Fatalf("wildcard %s was accepted", wildcard)
		}
	}
	if _, err := Addresses([]string{"bridge.example"}, true); err == nil {
		t.Fatal("hostname was accepted as a listen address")
	}
}

func TestOpenUsesOnlyConfiguredAddresses(t *testing.T) {
	var endpoints []string
	listen := func(network, address string) (net.Listener, error) {
		if network != "tcp" {
			t.Fatalf("network=%q, want tcp", network)
		}
		endpoints = append(endpoints, address)
		return &stubListener{address: stubAddress(address)}, nil
	}
	listeners, err := Open([]string{"127.0.0.1", "192.168.65.1", "::1"}, 17777, listen)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	defer closeAll(listeners)
	want := []string{"127.0.0.1:17777", "192.168.65.1:17777", "[::1]:17777"}
	if strings.Join(endpoints, ",") != strings.Join(want, ",") {
		t.Fatalf("endpoints=%v, want %v", endpoints, want)
	}
}

func TestOpenClosesPartialListenersOnBindFailure(t *testing.T) {
	first := &stubListener{address: stubAddress("127.0.0.1:17777")}
	calls := 0
	listen := func(_, _ string) (net.Listener, error) {
		calls++
		if calls == 1 {
			return first, nil
		}
		return nil, errors.New("address in use")
	}
	if _, err := Open([]string{"127.0.0.1", "192.168.65.1"}, 17777, listen); err == nil {
		t.Fatal("Open succeeded despite second bind failure")
	}
	if !first.closed {
		t.Fatal("partial listener was not closed")
	}
}

func TestSecondInstanceCannotBindSamePort(t *testing.T) {
	first, err := Open([]string{"127.0.0.1"}, 0, nil)
	if err != nil {
		t.Fatalf("first Open: %v", err)
	}
	defer closeAll(first)
	port := first[0].Addr().(*net.TCPAddr).Port
	second, err := Open([]string{"127.0.0.1"}, port, nil)
	if err == nil {
		closeAll(second)
		t.Fatal("second instance bound the same port")
	}
	if !strings.Contains(err.Error(), strconv.Itoa(port)) {
		t.Fatalf("bind error %q does not name port %d", err, port)
	}
}

func closeAll(listeners []net.Listener) {
	for _, listener := range listeners {
		_ = listener.Close()
	}
}

type stubAddress string

func (a stubAddress) Network() string { return "tcp" }
func (a stubAddress) String() string  { return string(a) }

type stubListener struct {
	address stubAddress
	closed  bool
}

func (l *stubListener) Accept() (net.Conn, error) {
	return nil, errors.New("not implemented")
}
func (l *stubListener) Close() error {
	l.closed = true
	return nil
}
func (l *stubListener) Addr() net.Addr { return l.address }

var _ net.Listener = (*stubListener)(nil)
