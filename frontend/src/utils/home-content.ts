import DOMPurify from 'dompurify'
import { sanitizeUrl } from './url'

const FORBIDDEN_HOME_TAGS = [
  'base',
  'button',
  'embed',
  'form',
  'iframe',
  'input',
  'link',
  'meta',
  'object',
  'option',
  'script',
  'select',
  'textarea',
]

export function sanitizeHomeContentHtml(html: string): string {
  return DOMPurify.sanitize(html, {
    USE_PROFILES: { html: true },
    FORBID_TAGS: FORBIDDEN_HOME_TAGS,
    FORBID_ATTR: ['formaction', 'srcdoc'],
    ALLOW_DATA_ATTR: false,
    SANITIZE_DOM: true,
    SANITIZE_NAMED_PROPS: true,
  })
}

export function sanitizeHomeContentUrl(value: string): string {
  return sanitizeUrl(value)
}
