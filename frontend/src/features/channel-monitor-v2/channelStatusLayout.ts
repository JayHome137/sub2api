export type ChannelStatusPlatformSection<T> = {
  platform: string
  rows: T[]
}

export type ChannelStatusLayoutBlock<T> =
  | { kind: 'cluster'; platform: string; rows: T[] }
  | { kind: 'compact'; items: Array<{ platform: string; row: T }> }

// OpenAI owns the first band; Claude and the remaining platforms share a grid.
export function buildChannelStatusLayout<T>(
  sections: ChannelStatusPlatformSection<T>[],
): ChannelStatusLayoutBlock<T>[] {
  const blocks: ChannelStatusLayoutBlock<T>[] = []
  const openai = sections.find(section => section.platform === 'openai')
  if (openai?.rows.length) {
    blocks.push({ kind: 'cluster', platform: openai.platform, rows: openai.rows })
  }
  const remaining = [
    ...sections.filter(section => section.platform === 'anthropic'),
    ...sections.filter(section => section.platform !== 'openai' && section.platform !== 'anthropic'),
  ]
  const items = remaining.flatMap(section => section.rows.map(row => ({ platform: section.platform, row })))
  if (items.length) blocks.push({ kind: 'compact', items })
  return blocks
}

export function channelStatusLayoutBlockKey<T>(block: ChannelStatusLayoutBlock<T>, index: number): string {
  if (block.kind === 'cluster') return `cluster:${block.platform}`
  return `compact:${index}:${block.items.map(item => item.platform).join('|')}`
}
