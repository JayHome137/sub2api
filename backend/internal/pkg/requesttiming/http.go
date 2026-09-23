package requesttiming

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"sync"
	"time"
)

type attemptKey struct{}
type Trace struct {
	c     *Collector
	index int
}

func StartAttempt(req *http.Request, accountID, proxyID int64) (*http.Request, *Trace) {
	c := From(req.Context())
	if c == nil {
		return req, nil
	}
	c.mu.Lock()
	if c.finished || len(c.data.Attempts) >= 32 {
		c.data.Truncated = true
		c.mu.Unlock()
		return req, nil
	}
	idx := len(c.data.Attempts)
	c.data.Attempts = append(c.data.Attempts, Attempt{Number: idx + 1, AccountID: accountID, ProxyID: proxyID, StartMS: c.offset(time.Now()), RequestBytes: req.ContentLength, Events: map[string]float64{}})
	c.mu.Unlock()
	t := &Trace{c: c, index: idx}
	ctx := context.WithValue(req.Context(), attemptKey{}, t)
	return req.Clone(httptrace.WithClientTrace(ctx, t.clientTrace())), t
}
func (t *Trace) update(fn func(*Attempt)) {
	if t == nil {
		return
	}
	t.c.mu.Lock()
	defer t.c.mu.Unlock()
	if !t.c.finished {
		fn(&t.c.data.Attempts[t.index])
	}
}
func (t *Trace) mark(name string) {
	t.update(func(a *Attempt) { a.Events[name] = t.c.offset(time.Now()) })
}
func (t *Trace) clientTrace() *httptrace.ClientTrace {
	return &httptrace.ClientTrace{
		GetConn: func(string) { t.mark("connection_start") },
		GotConn: func(i httptrace.GotConnInfo) {
			t.update(func(a *Attempt) { v := i.Reused; a.Reused = &v; a.Events["connection_ready"] = t.c.offset(time.Now()) })
		},
		DNSStart: func(httptrace.DNSStartInfo) { t.mark("dns_start") }, DNSDone: func(httptrace.DNSDoneInfo) { t.mark("dns_end") },
		ConnectStart: func(string, string) { t.mark("tcp_start") }, ConnectDone: func(string, string, error) { t.mark("tcp_end") },
		TLSHandshakeStart: func() { t.mark("tls_start") }, TLSHandshakeDone: func(tls.ConnectionState, error) { t.mark("tls_end") },
		WroteHeaders: func() { t.mark("headers_written") }, WroteRequest: func(i httptrace.WroteRequestInfo) {
			if i.Err == nil {
				t.mark("request_written")
			}
		},
		GotFirstResponseByte: func() { t.mark("first_byte") },
	}
}
func (t *Trace) Response(resp *http.Response, err error) {
	if t == nil {
		return
	}
	t.update(func(a *Attempt) {
		if err != nil {
			a.Error = errorKind(err)
		}
		if resp != nil {
			a.Status = resp.StatusCode
			a.Events["response_headers"] = t.c.offset(time.Now())
		}
		if err != nil || resp == nil || resp.Body == nil {
			v := t.c.offset(time.Now())
			a.EndMS = &v
		}
	})
	if resp != nil && resp.Body != nil {
		resp.Body = &responseBody{ReadCloser: resp.Body, trace: t}
	}
}
func errorKind(err error) string {
	if errors.Is(err, context.Canceled) {
		return "canceled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "timeout"
	}
	var ne net.Error
	if errors.As(err, &ne) && ne.Timeout() {
		return "timeout"
	}
	return "transport_error"
}

type responseBody struct {
	io.ReadCloser
	trace *Trace
	once  sync.Once
}

func (b *responseBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	b.trace.update(func(a *Attempt) {
		a.ResponseBytes += int64(n)
		if err == io.EOF {
			a.BodyEOF = true
		} else if err != nil {
			a.Error = errorKind(err)
		}
	})
	if err != nil {
		b.end()
	}
	return n, err
}
func (b *responseBody) end() {
	b.once.Do(func() { b.trace.update(func(a *Attempt) { v := b.trace.c.offset(time.Now()); a.EndMS = &v }) })
}
func (b *responseBody) Close() error { err := b.ReadCloser.Close(); b.end(); return err }
