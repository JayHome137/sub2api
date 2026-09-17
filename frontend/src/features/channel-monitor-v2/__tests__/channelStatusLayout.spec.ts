import { describe, expect, it } from 'vitest'
import { buildChannelStatusLayout } from '../channelStatusLayout'

describe('buildChannelStatusLayout', () => {
  it('keeps only OpenAI as a labeled cluster', () => {
    const blocks = buildChannelStatusLayout([
      { platform: 'openai', rows: [{ id: 1 }, { id: 2 }] },
      { platform: 'gemini', rows: [{ id: 3 }, { id: 4 }, { id: 5 }] },
    ])
    expect(blocks).toEqual([
      { kind: 'cluster', platform: 'openai', rows: [{ id: 1 }, { id: 2 }] },
      { kind: 'compact', items: [3, 4, 5].map(id => ({ platform: 'gemini', row: { id } })) },
    ])
  })

  it('packs consecutive single-group platforms into one compact row', () => {
    const blocks = buildChannelStatusLayout([
      { platform: 'openai', rows: [{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }] },
      { platform: 'anthropic', rows: [{ id: 5 }] },
      { platform: 'grok', rows: [{ id: 6 }] },
      { platform: 'gemini', rows: [{ id: 7 }, { id: 8 }] },
    ])
    expect(blocks.map(block => block.kind)).toEqual(['cluster', 'compact'])
    expect(blocks[1]).toEqual({
      kind: 'compact',
      items: [
        { platform: 'anthropic', row: { id: 5 } },
        { platform: 'grok', row: { id: 6 } },
        { platform: 'gemini', row: { id: 7 } },
        { platform: 'gemini', row: { id: 8 } },
      ],
    })
  })

  it('pins OpenAI first even when other groups have earlier IDs', () => {
    const blocks = buildChannelStatusLayout([
      { platform: 'anthropic', rows: [{ id: 1 }] },
      { platform: 'openai', rows: [{ id: 2 }, { id: 3 }] },
      { platform: 'grok', rows: [{ id: 4 }] },
    ])
    expect(blocks.map(block => block.kind)).toEqual(['cluster', 'compact'])
    expect(blocks[0]).toMatchObject({ platform: 'openai' })
  })

  it('renders an all-singleton board as one compact grid', () => {
    const blocks = buildChannelStatusLayout([
      { platform: 'anthropic', rows: [{ id: 1 }] },
      { platform: 'grok', rows: [{ id: 2 }] },
      { platform: 'kimi', rows: [{ id: 3 }] },
    ])
    expect(blocks).toHaveLength(1)
    expect(blocks[0]?.kind).toBe('compact')
  })

  it('pins a single OpenAI group and starts the shared grid with Claude', () => {
    expect(buildChannelStatusLayout([
      { platform: 'kimi', rows: [1, 2] },
      { platform: 'openai', rows: [3] },
      { platform: 'anthropic', rows: [4, 5] },
    ])).toEqual([
      { kind: 'cluster', platform: 'openai', rows: [3] },
      { kind: 'compact', items: [
        { platform: 'anthropic', row: 4 }, { platform: 'anthropic', row: 5 },
        { platform: 'kimi', row: 1 }, { platform: 'kimi', row: 2 },
      ] },
    ])
  })

  it('omits empty sections without adding groups or empty bands', () => {
    expect(buildChannelStatusLayout([{ platform: 'openai', rows: [] }])).toEqual([])
    expect(buildChannelStatusLayout([])).toEqual([])
  })
})
