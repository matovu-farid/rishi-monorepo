export function Footer() {
  return (
    <footer className="border-t border-border py-12 px-6">
      <div className="max-w-7xl mx-auto">
        <div className="grid md:grid-cols-4 gap-8 mb-12">
          <div>
            <div className="flex items-center gap-2 mb-4">
              <div className="w-8 h-8 rounded-lg bg-gradient-to-br from-amber-500 to-orange-500 flex items-center justify-center">
                <span className="text-white font-bold text-sm">R</span>
              </div>
              <span className="font-bold">Rishi</span>
            </div>
            <p className="text-sm text-muted-foreground">
              Making reading more meaningful, one conversation at a time.
            </p>
          </div>

          {[
            {
              title: 'Product',
              links: ['Features', 'Pricing', 'Download', 'Changelog']
            },
            {
              title: 'Resources',
              links: ['Documentation', 'Blog', 'FAQ', 'Support']
            },
            {
              title: 'Company',
              links: ['About', 'Contact', 'Privacy', 'Terms']
            }
          ].map((col, i) => (
            <div key={i}>
              <h4 className="font-semibold mb-4 text-foreground">{col.title}</h4>
              <ul className="space-y-2">
                {col.links.map((link, j) => (
                  <li key={j}>
                    <a href="#" className="text-sm text-muted-foreground hover:text-foreground transition">
                      {link}
                    </a>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>

        <div className="border-t border-border pt-8 flex flex-col md:flex-row justify-between items-center gap-4">
          <p className="text-sm text-muted-foreground">
            © 2025 Rishi. All rights reserved.
          </p>
          <div className="flex gap-6">
            <a href="#" className="text-sm text-muted-foreground hover:text-foreground transition">Twitter</a>
            <a href="#" className="text-sm text-muted-foreground hover:text-foreground transition">Discord</a>
            <a href="#" className="text-sm text-muted-foreground hover:text-foreground transition">GitHub</a>
          </div>
        </div>
      </div>
    </footer>
  )
}
