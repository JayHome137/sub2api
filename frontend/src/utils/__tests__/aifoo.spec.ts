import { describe, expect, it } from 'vitest'
import { aifooNavHeading, aifooRouteClass, isAifooConsolePath } from '../aifoo'

describe('AIFoo source-integrated shell', () => {
  it('derives stable route classes without patching browser history', () => {
    expect(aifooRouteClass('/admin/ops')).toBe('route-admin-ops')
    expect(aifooRouteClass('/custom/da6c757dc4878b90')).toBe('route-custom-da6c757dc4878b90')
  })

  it('marks protected and custom routes before Vue mounts', () => {
    expect(isAifooConsolePath('/dashboard')).toBe(true)
    expect(isAifooConsolePath('/admin/accounts')).toBe(true)
    expect(isAifooConsolePath('/custom/menu-id')).toBe(true)
    expect(isAifooConsolePath('/login')).toBe(false)
  })

  it('emits each sidebar group heading once', () => {
    const paths = ['/admin/dashboard', '/admin/users', '/admin/channels', '/admin/accounts', '/admin/settings']
    expect(paths.map((_, index) => aifooNavHeading(paths, index))).toEqual([
      '控制中心',
      '',
      '渠道与资源',
      '',
      '系统配置'
    ])
  })
})
