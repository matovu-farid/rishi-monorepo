export function magicLinkEmail({ url }: { url: string }): string {
  return `<!DOCTYPE html>
<html><body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;max-width:520px;margin:40px auto;color:#1a1a1a">
  <h1 style="font-size:22px;margin-bottom:24px">Sign in to Rishi</h1>
  <p style="font-size:15px;line-height:1.5">Click the button below to sign in. This link expires in 10 minutes.</p>
  <p style="margin:32px 0">
    <a href="${url}" style="background:#1a1a1a;color:#fff;padding:12px 24px;border-radius:8px;text-decoration:none;font-weight:500">Sign in to Rishi</a>
  </p>
  <p style="font-size:13px;color:#666;line-height:1.5">If the button doesn't work, paste this link in your browser:<br><a href="${url}" style="color:#666;word-break:break-all">${url}</a></p>
  <p style="font-size:13px;color:#666;line-height:1.5;margin-top:32px">If you didn't request this, ignore this email.</p>
</body></html>`
}
