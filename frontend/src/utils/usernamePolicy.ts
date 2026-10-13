export const USERNAME_MAX_RUNES = 50

const USERNAME_ALLOWED_RE = /^[\p{L}\p{N} _.-]+$/u

export function isUsernameValid(raw: string): boolean {
  const value = String(raw || '').trim()
  return !value || (Array.from(value).length <= USERNAME_MAX_RUNES && USERNAME_ALLOWED_RE.test(value))
}
