import Image from "next/image";

export function Footer() {
  return (
    <footer className="border-t border-border py-12 px-6">
      <div className="max-w-7xl mx-auto">
        <div className="grid md:grid-cols-4 gap-8 mb-12">
          <div>
            <div className="flex items-center gap-2 mb-4">
              <Image src="/brand/rishi-icon.png" alt="" width={32} height={32} className="rounded-lg" />
              <span className="font-bold">Rishi</span>
            </div>
            <p className="text-sm text-muted-foreground">
              Making reading more meaningful, one conversation at a time.
            </p>
          </div>

          {[
            {
              title: 'Product',
              links: [
                { label: 'Features', href: '/#features' },
                { label: 'Pricing', href: '/pricing' },
                { label: 'Changelog', href: '/changelog' },
              ]
            },
            {
              title: 'Resources',
              links: [
                { label: 'Documentation', href: '/docs' },
                { label: 'Blog', href: '/blog' },
                { label: 'FAQ', href: '/support' },
                { label: 'Support', href: '/support' },
              ]
            },
            {
              title: 'Company',
              links: [
                { label: 'About', href: 'https://fidexa.org', external: true },
                { label: 'Contact', href: '/support' },
                { label: 'Privacy', href: '/privacy' },
                { label: 'Terms', href: '/terms' },
              ]
            }
          ].map((col, i) => (
            <div key={i}>
              <h4 className="font-semibold mb-4 text-foreground">{col.title}</h4>
              <ul className="space-y-2">
                {col.links.map((link, j) => (
                  <li key={j}>
                    <a href={link.href} {...('external' in link ? { target: '_blank', rel: 'noopener noreferrer' } : {})} className="text-sm text-muted-foreground hover:text-foreground transition">
                      {link.label}
                    </a>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="border-t border-border pt-8 flex flex-col md:flex-row justify-between items-center gap-4">
          <p className="text-sm text-muted-foreground">
            © 2026 Rishi. All rights reserved.
          </p>
          <div className="flex gap-6">
            <a href="https://twitter.com/matovu100" target="_blank" rel="noopener noreferrer" className="text-sm text-muted-foreground hover:text-foreground transition">Twitter</a>
            <a href="https://discord.gg" target="_blank" rel="noopener noreferrer" className="text-sm text-muted-foreground hover:text-foreground transition">Discord</a>
            <a href="https://github.com/matovu-farid" target="_blank" rel="noopener noreferrer" className="text-sm text-muted-foreground hover:text-foreground transition">GitHub</a>
          </div>
        </div>
      </div>
    </footer>
  )
}
