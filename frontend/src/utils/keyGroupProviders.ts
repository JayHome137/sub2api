import type { GroupPlatform } from '@/types'

export type KeyGroupProvider = 'anthropic' | 'openai' | 'domestic' | 'other'

export const KEY_GROUP_PROVIDERS = ['anthropic', 'openai', 'domestic', 'other'] as const

// Classify by the configured upstream platform, never by a group's display name.
// Keep the input string-based so newer backend platforms remain safe fallbacks
// while this AIFoo frontend stays on its existing platform type snapshot.
const PROVIDER_BY_PLATFORM: Record<string, KeyGroupProvider> = {
  anthropic: 'anthropic',
  openai: 'openai',
  kimi: 'domestic',
  zhipu: 'domestic',
  deepseek: 'domestic',
  minimax: 'domestic',
  gemini: 'other',
  grok: 'other',
  antigravity: 'other',
  composite: 'other',
  opencode_go: 'other'
}

export function getKeyGroupProvider(platform: string): KeyGroupProvider {
  return PROVIDER_BY_PLATFORM[platform] ?? 'other'
}

// Collections use representative platform marks rather than invented brand logos.
export const KEY_GROUP_PROVIDER_ICONS: Record<KeyGroupProvider, GroupPlatform[]> = {
  anthropic: ['anthropic'],
  openai: ['openai'],
  domestic: ['deepseek', 'kimi'],
  other: ['gemini', 'grok']
}
