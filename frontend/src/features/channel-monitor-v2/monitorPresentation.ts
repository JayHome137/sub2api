import type { MonitorHealth, MonitorMetric } from '@/api/channelMonitorV2'

// User responses redact absolute counters, so zero counters alone prove nothing.
export function monitorAvailability(metric: MonitorMetric, health: MonitorHealth): number | null {
  const observed = metric.request_count > 0 || metric.rpm > 0 || metric.error_rate > 0
    || metric.ttft.p50_ms != null || metric.duration.p50_ms != null || metric.cache_rate > 0
    || health.error_rate !== 'unknown'
  return observed ? 1 - metric.error_rate : null
}

export function monitorCacheRate(metric: MonitorMetric, health: MonitorHealth): number | null {
  const observed = metric.cache_rate_denominator > 0 || metric.cache_rate > 0
    || (health.cache != null && health.cache !== 'unknown')
  return observed ? metric.cache_rate : null
}
