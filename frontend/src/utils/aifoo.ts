const NAV_GROUPS = [
  { prefix: '/admin/dashboard', label: '控制中心' },
  { prefix: '/admin/ops', label: '控制中心' },
  { prefix: '/admin/users', label: '控制中心' },
  { prefix: '/admin/groups', label: '控制中心' },
  { prefix: '/admin/channels', label: '渠道与资源' },
  { prefix: '/admin/subscriptions', label: '渠道与资源' },
  { prefix: '/admin/accounts', label: '渠道与资源' },
  { prefix: '/admin/announcements', label: '渠道与资源' },
  { prefix: '/admin/proxies', label: '风控与网络' },
  { prefix: '/admin/security-audit', label: '风控与网络' },
  { prefix: '/admin/risk-control', label: '风控与网络' },
  { prefix: '/admin/prompt-audit', label: '风控与网络' },
  { prefix: '/admin/redeem', label: '增长工具' },
  { prefix: '/admin/promo-codes', label: '增长工具' },
  { prefix: '/admin/affiliates', label: '增长工具' },
  { prefix: '/admin/orders', label: '订单与统计' },
  { prefix: '/admin/usage', label: '订单与统计' },
  { prefix: '/admin/audit-logs', label: '订单与统计' },
  { prefix: '/admin/settings', label: '系统配置' },
  { prefix: '/dashboard', label: '' },
  { prefix: '/keys', label: 'API' },
  { prefix: '/batch-image', label: 'API' },
  { prefix: '/usage', label: 'API' },
  { prefix: '/available-channels', label: 'API' },
  { prefix: '/monitor', label: 'API' },
  { prefix: '/custom/', label: 'API' },
  { prefix: '/subscriptions', label: '账单' },
  { prefix: '/purchase', label: '账单' },
  { prefix: '/orders', label: '账单' },
  { prefix: '/redeem', label: '账单' },
  { prefix: '/affiliate', label: '账单' },
  { prefix: '/profile', label: '其他' }
] as const

const CONSOLE_PATHS = new Set([
  '/dashboard',
  '/keys',
  '/batch-image',
  '/usage',
  '/monitor',
  '/channel-status',
  '/purchase',
  '/orders',
  '/subscriptions',
  '/redeem',
  '/affiliate',
  '/profile',
  '/available-channels'
])

export function isAifooConsolePath(path: string): boolean {
  return CONSOLE_PATHS.has(path) || path.startsWith('/admin/') || path === '/admin' || path.startsWith('/custom/')
}

export function aifooRouteClass(path: string): string {
  const slug = path
    .replace(/^\/+|\/+$/g, '')
    .replace(/[^a-zA-Z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')

  return slug ? `route-${slug}` : ''
}

export function aifooNavGroup(path: string): string {
  return NAV_GROUPS.find(({ prefix }) => path.startsWith(prefix))?.label ?? ''
}

export function aifooNavHeading(paths: string[], index: number): string {
  const current = aifooNavGroup(paths[index] ?? '')
  if (!current) return ''

  const previous = index > 0 ? aifooNavGroup(paths[index - 1] ?? '') : ''
  return current === previous ? '' : current
}
