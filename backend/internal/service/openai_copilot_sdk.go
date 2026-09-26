package service

import (
	"context"
	"io"
)

// Stateful SDK turns must see downstream cancellation so that the next turn
// cannot race a still-running agent. Ordinary providers retain usage draining.
func openAIPassthroughContext(ctx context.Context, account *Account) (context.Context, context.CancelFunc) {
	if account.IsCopilotSDKEnabled() && ctx != nil {
		return ctx, func() {}
	}
	return detachUpstreamContext(ctx)
}

// closeResponseBodyOnContextCancel makes streaming reads observe downstream
// cancellation even when the response body implementation does not watch the
// request context itself (for example, an io.Pipe in a test or sidecar).
func closeResponseBodyOnContextCancel(ctx context.Context, body io.Closer) func() {
	if ctx == nil || body == nil {
		return func() {}
	}
	stop := context.AfterFunc(ctx, func() { _ = body.Close() })
	return func() { _ = stop() }
}
