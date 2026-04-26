export function shouldDebug(): boolean {
  try {
    return localStorage.getItem('rishi:debug') === '1'
  } catch {
    return false
  }
}
