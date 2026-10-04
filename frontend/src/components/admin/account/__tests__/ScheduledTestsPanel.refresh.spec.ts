import { enableAutoUnmount, flushPromises, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
const mocks = vi.hoisted(() => ({ list: vi.fn(), results: vi.fn(), account: vi.fn() }))
vi.mock('@/api/admin', () => ({ adminAPI: { scheduledTests: { listByAccount: mocks.list, listResults: mocks.results }, accounts: { getById: mocks.account } } }))
vi.mock('@/stores/app', () => ({ useAppStore: () => ({ showError: vi.fn() }) }))
vi.mock('vue-i18n', async (importOriginal) => ({ ...await importOriginal<typeof import('vue-i18n')>(), useI18n: () => ({ t: (key: string) => key }) }))
import ScheduledTestsPanel from '../ScheduledTestsPanel.vue'
enableAutoUnmount(afterEach)
const plan = { id: 7, account_id: 1, model_id: 'model', cron_expression: '*/30 * * * *', enabled: true, quality_check_enabled: true, quality_mode: 'candy', max_results: 100 }
const result = (id: number) => ({ id, plan_id: 7, status: 'success', quality_mode: 'candy', response_text: '29', started_at: '2026-10-04T12:00:00Z', latency_ms: 100 })
const create = () => mount(ScheduledTestsPanel, { props: { show: false, accountId: 1, modelOptions: [] }, global: { stubs: { BaseDialog: { template: '<div><slot /></div>' }, ConfirmDialog: true, HelpTooltip: true, Select: true, Input: true, Toggle: true, Icon: true } } })
describe('scheduled result refresh', () => {
 beforeEach(() => { vi.useFakeTimers(); vi.clearAllMocks(); mocks.list.mockResolvedValue([plan]); mocks.results.mockResolvedValue([result(100)]); mocks.account.mockResolvedValue({ extra: { scheduled_quality_auto_pause_enabled: false } }); vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('visible') })
 afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks() })
 it('fetches only new results, retains selection and pauses while hidden', async () => {
  const wrapper = create()
  await wrapper.setProps({ show: true }); await flushPromises()
  const button = wrapper.find('.cursor-pointer')
  expect(button).toBeTruthy(); await button.trigger('click'); await flushPromises()
  expect(mocks.results).toHaveBeenLastCalledWith(7, 20)
  mocks.results.mockResolvedValue([result(101)])
  await vi.advanceTimersByTimeAsync(15000); await flushPromises()
  expect(mocks.results).toHaveBeenLastCalledWith(7, 20, 100)
  expect(wrapper.text()).toContain('#101'); expect(wrapper.text()).toContain('#100')
  expect(wrapper.find('pre').text()).toBe('29')
  const count = mocks.results.mock.calls.length
  vi.spyOn(document, 'visibilityState', 'get').mockReturnValue('hidden')
  await vi.advanceTimersByTimeAsync(30000)
  expect(mocks.results).toHaveBeenCalledTimes(count)
  await wrapper.setProps({ show: false }); await vi.advanceTimersByTimeAsync(30000)
  expect(mocks.results).toHaveBeenCalledTimes(count)
 })
 it('discards result responses from the previous account', async () => {
  const wrapper = create(); await wrapper.setProps({ show: true }); await flushPromises()
  let resolve!: (value: unknown[]) => void
  mocks.results.mockReturnValue(new Promise(r => { resolve = r }))
  await wrapper.find('.cursor-pointer').trigger('click')
  mocks.list.mockResolvedValue([])
  await wrapper.setProps({ accountId: 2 }); await flushPromises()
  resolve([result(999)]); await flushPromises()
  expect(wrapper.text()).not.toContain('#999')
 })
})
