import { flushPromises, mount } from '@vue/test-utils'
import { describe, expect, it, vi } from 'vitest'
import UsageTimingDialog from '../UsageTimingDialog.vue'
import type { AdminUsageLog } from '@/types'
const mocks = vi.hoisted(() => ({ get: vi.fn() }))
vi.mock('@/api/admin/usageTiming', () => ({ getUsageTiming: mocks.get }))
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: (key: string) => key }) }))
vi.mock('@/utils/format', () => ({ formatDateTime: (s: string) => s }))
const row = (id: number) => ({ id, model: 'test', request_id: `r${id}`, first_token_ms: 6055, duration_ms: 6067, created_at: '2026-09-23' }) as AdminUsageLog
const options = { global: { stubs: { BaseDialog: { template: '<section><slot /></section>' } } } }
describe('Usage timing details', () => {
  it('keeps historical values and marks missing details instead of inventing zeros', async () => {
    mocks.get.mockResolvedValue({ traces: [], retention_days: 30 })
    const wrapper = mount(UsageTimingDialog, { props: { record: row(1) }, ...options })
    await flushPromises()
    expect(wrapper.text()).toContain('6.05s')
    expect(wrapper.text()).toContain('6.07s')
    expect(wrapper.text()).toContain('requestTiming.empty')
    expect(wrapper.text()).toContain('requestTiming.missing')
    wrapper.unmount()
  })
  it('ignores stale responses when switching records', async () => {
    let resolveOld!: (data: unknown) => void
    mocks.get.mockImplementationOnce(() => new Promise(resolve => { resolveOld = resolve }))
    mocks.get.mockResolvedValueOnce({ traces: [], retention_days: 30 })
    const wrapper = mount(UsageTimingDialog, { props: { record: row(1) }, ...options })
    await wrapper.setProps({ record: row(2) }); await flushPromises()
    resolveOld({ traces: [{ trace_id: 'stale' }], retention_days: 30 }); await flushPromises()
    expect(wrapper.text()).not.toContain('stale')
    expect(wrapper.text()).toContain('r2')
    wrapper.unmount()
  })
})
