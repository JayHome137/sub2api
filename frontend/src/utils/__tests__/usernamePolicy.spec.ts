import { describe, expect, it } from 'vitest'
import { isUsernameValid } from '@/utils/usernamePolicy'

describe('usernamePolicy', () => {
  it('accepts the supported display-name characters', () => {
    expect(isUsernameValid('张三 Alice_1')).toBe(true)
  })

  it('rejects markup and names longer than 50 characters', () => {
    expect(isUsernameValid('<svg onload=x>')).toBe(false)
    expect(isUsernameValid('名'.repeat(51))).toBe(false)
  })
})
