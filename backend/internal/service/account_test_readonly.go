package service

import (
	"context"
	"time"
)

// accountTestWriteAllowed keeps the normal administrator test behavior intact
// while making quality probes observational only.
func accountTestWriteAllowed(ctx context.Context) bool {
	return !isReadOnlyAccountTest(ctx)
}

func readOnlyOAuthToken(account *Account) (string, bool) {
	if account == nil {
		return "", false
	}
	token := account.GetCredential("access_token")
	if token == "" {
		return "", false
	}
	if expiresAt := account.GetCredentialAsTime("expires_at"); expiresAt != nil && !expiresAt.After(time.Now()) {
		return "", false
	}
	return token, true
}

// accountTestReadOnlyContextKey marks probes that must not update account
// scheduling state, credentials, or probe metadata.
type accountTestReadOnlyContextKey struct{}

func withReadOnlyAccountTest(ctx context.Context) context.Context {
	return context.WithValue(ctx, accountTestReadOnlyContextKey{}, true)
}

func isReadOnlyAccountTest(ctx context.Context) bool {
	readOnly, _ := ctx.Value(accountTestReadOnlyContextKey{}).(bool)
	return readOnly
}
