// Same baseline and boundaries as backend ops_health_score.go.
export function ttftHealthLevel(value: number | null, baseline: number | null | undefined): 'normal' | 'warning' | 'critical' {
  if (value == null || !Number.isFinite(value)) return 'normal'
  const t = baseline != null && Number.isFinite(baseline) && baseline > 0 ? baseline : 500
  if (value >= 2 * t) return 'critical'
  if (value > t) return 'warning'
  return 'normal'
}
