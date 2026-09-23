package requesttiming

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestFinishAndBindingEitherOrder(t *testing.T) {
	for _, finishFirst := range []bool{false, true} {
		t.Run(map[bool]string{false: "bind_first", true: "finish_first"}[finishFirst], func(t *testing.T) {
			c := New(time.Now(), 3)
			ctx := With(context.Background(), c)
			body := c.WrapBody(io.NopCloser(strings.NewReader("abc")))
			if _, err := io.ReadAll(body); err != nil {
				t.Fatal(err)
			}
			done := Observe(ctx, "check")
			done()
			done()
			var got Snapshot
			calls := 0
			if finishFirst {
				c.Finish(200, false)
			}
			c.WhenFinished(func(s Snapshot) { got = s; calls++ })
			c.Finish(200, false)
			c.Finish(500, true)
			if calls != 1 || got.Status != 200 || got.BodyBytes != 3 || !got.BodyComplete || len(got.Spans) != 1 {
				t.Fatalf("unexpected snapshot: %+v, calls %d", got, calls)
			}
			Mark(ctx, "too_late")
			if _, ok := got.Events["too_late"]; ok {
				t.Fatal("snapshot mutated")
			}
		})
	}
}
func TestConcurrentCallbacksAndBounds(t *testing.T) {
	c := New(time.Now(), -1)
	ctx := With(context.Background(), c)
	var wg sync.WaitGroup
	for range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range 30 {
				Observe(ctx, "span")()
				Mark(ctx, "one")
				Output(ctx, true, false, "")
			}
		}()
	}
	wg.Wait()
	c.Finish(200, false)
	c.WhenFinished(func(s Snapshot) {
		if len(s.Spans) != 256 || !s.Truncated {
			t.Fatal("missing bounds")
		}
	})
}
func TestHTTPTraceKeepsOuterHooksAndReuse(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.Copy(io.Discard, r.Body)
		_, _ = w.Write([]byte("ok"))
	}))
	defer server.Close()
	c := New(time.Now(), 0)
	client := server.Client()
	for range 2 {
		req, _ := http.NewRequestWithContext(With(context.Background(), c), "POST", server.URL, strings.NewReader("hello"))
		req, tr := StartAttempt(req, 7, 0)
		resp, err := client.Do(req)
		tr.Response(resp, err)
		if err != nil {
			t.Fatal(err)
		}
		_, _ = io.ReadAll(resp.Body)
		_ = resp.Body.Close()
	}
	c.Finish(200, false)
	c.WhenFinished(func(s Snapshot) {
		if len(s.Attempts) != 2 {
			t.Fatal("lost attempts")
		}
		for _, a := range s.Attempts {
			if !a.BodyEOF || a.ResponseBytes != 2 || a.Events["request_written"] == 0 || a.Events["first_byte"] == 0 {
				t.Fatalf("incomplete trace %+v", a)
			}
		}
		if s.Attempts[1].Reused == nil || !*s.Attempts[1].Reused {
			t.Fatal("reuse missing")
		}
	})
}
