package service

import (
	"unicode/utf8"

	infraerrors "github.com/Wei-Shaw/sub2api/internal/pkg/errors"
)

const MinPasswordLength = 8

var ErrPasswordTooShort = infraerrors.BadRequest("PASSWORD_TOO_SHORT", "password must be at least 8 characters")

// ValidateNewPassword applies only when setting a new password. Existing
// passwords remain valid for login and credential confirmation.
func ValidateNewPassword(password string) error {
	if utf8.RuneCountInString(password) < MinPasswordLength {
		return ErrPasswordTooShort
	}
	return nil
}
