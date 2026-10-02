import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const getQualityEvents = vi.fn()

vi.mock('@/api/channelMonitorV2', () => ({
  getQualityEvents: (...args: unknown[]) => getQualityEvents(...args),
  getQualityEventArtwork: vi.fn(),
}))
vi.mock('vue-i18n', async (importOriginal) => {
  const actual = await importOriginal<typeof import('vue-i18n')>()
  return {
    ...actual,
    useI18n: () => ({ t: (key: string) => key, locale: { value: 'zh-CN' } }),
  }
})

import ChannelMonitorV3QualityHistory from '../ChannelMonitorV3QualityHistory.vue'

enableAutoUnmount(afterEach)

describe('ChannelMonitorV3QualityHistory refresh', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    getQualityEvents.mockResolvedValue([])
  })

  it('reloads group results when the monitor refresh revision changes', async () => {
    const wrapper = mount(ChannelMonitorV3QualityHistory, {
      props: { groupId: 17, enabled: true, refreshRevision: 1 },
    })
    await flushPromises()
    expect(getQualityEvents).toHaveBeenCalledTimes(1)
    expect(getQualityEvents).toHaveBeenLastCalledWith(17, 30)

    getQualityEvents.mockResolvedValue([{
      id: 82,
      group_id: 17,
      account_id: 3,
      model_id: 'gpt-5',
      status: 'degraded',
      quality_mode: 'candy',
      error_message: '',
      created_at: '2026-10-02T04:00:00Z',
    }])
    await wrapper.setProps({ refreshRevision: 2 })
    await flushPromises()

    expect(getQualityEvents).toHaveBeenCalledTimes(2)
    expect(wrapper.text()).toContain('monitorCommon.qualityHistoryDegraded')
  })
})
