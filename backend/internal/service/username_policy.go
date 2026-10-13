package service

import (
	"strings"
	"unicode"
	"unicode/utf8"

	infraerrors "github.com/Wei-Shaw/sub2api/internal/pkg/errors"
)

const MaxUsernameRunes = 50

var ErrUsernameInvalid = infraerrors.BadRequest(
	"USERNAME_INVALID",
	"username may only contain letters, numbers, spaces and _-. (max 50 characters)",
)

func ValidateUsername(raw string) error {
	value := strings.TrimSpace(raw)
	if value == "" || utf8.RuneCountInString(value) > MaxUsernameRunes {
		return ErrUsernameInvalid
	}
	for _, r := range value {
		if !isUsernameRune(r) {
			return ErrUsernameInvalid
		}
	}
	return nil
}

func SanitizeUsername(raw string) string {
	value := strings.TrimSpace(raw)
	if value == "" {
		return ""
	}
	out := make([]rune, 0, MaxUsernameRunes)
	for _, r := range value {
		if !isUsernameRune(r) {
			continue
		}
		out = append(out, r)
		if len(out) == MaxUsernameRunes {
			break
		}
	}
	return strings.TrimSpace(string(out))
}

func isUsernameRune(r rune) bool {
	return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' || r == '-' || r == '.' || r == ' '
}
