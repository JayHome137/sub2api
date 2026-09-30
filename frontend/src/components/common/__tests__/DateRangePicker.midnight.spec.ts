import { enableAutoUnmount, mount } from '@vue/test-utils'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick, ref } from 'vue'
import DateRangePicker from '../DateRangePicker.vue'
vi.mock('vue-i18n', () => ({ useI18n: () => ({ t: (key: string) => key, locale: ref('en') }) }))
enableAutoUnmount(afterEach)
beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(new Date(2026, 8, 30, 23, 59)) })
afterEach(() => {
  document.body.querySelectorAll('.date-picker-dropdown').forEach((node) => node.remove())
  vi.useRealTimers()
})
const currentDropdown = () => Array.from(document.body.querySelectorAll<HTMLElement>('.date-picker-dropdown')).at(-1)
async function reopenNextDay() {
  const w = mount(DateRangePicker, { props: { startDate: '2026-09-30', endDate: '2026-09-30' }, global: { stubs: { Icon: true } } })
  await w.get('.date-picker-trigger').trigger('click')
  await nextTick()
  const initialDropdown = currentDropdown()
  expect(initialDropdown?.querySelectorAll<HTMLInputElement>('input[type="date"]')[1]?.getAttribute('max')).toBe('2026-10-01')
  await w.get('.date-picker-trigger').trigger('click')
  vi.setSystemTime(new Date(2026, 9, 1, 0, 1))
  await w.get('.date-picker-trigger').trigger('click')
  await nextTick()
  return w
}
describe('date presets after midnight', () => {
  it.each([
    ['dates.today', '2026-10-01'],
    ['dates.last7Days', '2026-09-25'],
    ['dates.thisMonth', '2026-10-01'],
  ])('refreshes %s when the page stays mounted overnight', async (label, startDate) => {
    const w = await reopenNextDay()
    const dropdown = currentDropdown()
    const preset = Array.from(dropdown?.querySelectorAll<HTMLButtonElement>('.date-picker-preset') ?? [])
      .find(b => b.textContent === label)
    expect(preset).toBeDefined()
    preset!.click()
    await nextTick()
    dropdown?.querySelector<HTMLButtonElement>('.date-picker-apply')!.click()
    await nextTick()
    expect(w.emitted('change')?.[0]?.[0]).toMatchObject({ startDate, endDate: '2026-10-01' })
  })
  it('updates the maximum selectable date when reopened', async () => {
    const w = await reopenNextDay()
    const dropdown = currentDropdown()
    expect(dropdown?.querySelectorAll<HTMLInputElement>('input[type="date"]')[1]?.getAttribute('max')).toBe('2026-10-02')
  })
})
