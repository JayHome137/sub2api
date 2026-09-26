export type SiteBillingMode = 'recharge_and_subscription' | 'recharge_only' | 'subscription_only'

export const SITE_BILLING_MODES: readonly SiteBillingMode[] = [
  'recharge_and_subscription',
  'recharge_only',
  'subscription_only'
]

export const SITE_BILLING_MODE_I18N_KEYS: Record<SiteBillingMode, string> = {
  recharge_and_subscription: 'rechargeAndSubscription',
  recharge_only: 'rechargeOnly',
  subscription_only: 'subscriptionOnly'
}

export interface BillingModeSettings {
  subscription_enabled?: boolean
  payment_balance_disabled?: boolean
}

export function resolveSiteBillingMode(settings: BillingModeSettings | null | undefined): SiteBillingMode {
  const subscriptionEnabled = settings?.subscription_enabled !== false
  if (!subscriptionEnabled) return 'recharge_only'
  if (settings?.payment_balance_disabled === true) return 'subscription_only'
  return 'recharge_and_subscription'
}

export function billingModeToSettings(mode: SiteBillingMode): Required<BillingModeSettings> {
  switch (mode) {
    case 'recharge_only':
      return { subscription_enabled: false, payment_balance_disabled: false }
    case 'subscription_only':
      return { subscription_enabled: true, payment_balance_disabled: true }
    default:
      return { subscription_enabled: true, payment_balance_disabled: false }
  }
}
