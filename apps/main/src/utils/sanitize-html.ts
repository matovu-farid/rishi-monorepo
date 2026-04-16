import DOMPurify from 'dompurify';

const FORBID_TAGS = ['script', 'iframe', 'object', 'embed', 'frame', 'frameset', 'meta', 'link'];

// Defense-in-depth list. DOMPurify's default allowlist already drops every
// inline `on*` event handler, so this `FORBID_ATTR` array is illustrative
// of what we explicitly do not want, not the actual security mechanism.
// Do not rely on this list being complete — rely on DOMPurify's allowlist.
const FORBID_ATTR = [
  'onload', 'onerror', 'onclick', 'onmouseover', 'onmouseout', 'onmousedown', 'onmouseup',
  'onkeydown', 'onkeyup', 'onkeypress', 'onfocus', 'onblur', 'onchange', 'onsubmit',
  'onreset', 'onselect', 'onabort', 'onresize', 'onscroll', 'onunload', 'oninput',
  'onbeforeunload', 'oncopy', 'oncut', 'onpaste', 'ondrag', 'ondrop', 'ontoggle',
  'onanimationstart', 'onanimationend', 'onanimationiteration',
];

// Only safe raster image MIME types with base64 encoding are allowed under data:.
// The `;base64,` anchor prevents data:image/png,<html>... tricks.
// data:image/svg+xml is intentionally excluded — SVG can execute scripts in img context.
const ALLOWED_URI_REGEXP =
  /^(?:(?:blob|https?):|#|data:image\/(?:png|jpe?g|gif|webp|avif|bmp);base64,|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i;

// DOMPurify's internal DATA_URI_TAGS fallback allows any data: URI on <img src>
// regardless of ALLOWED_URI_REGEXP. This hook enforces the tighter allowlist on
// every URI attribute after DOMPurify's own checks, closing that bypass.
const URI_ATTRS = new Set(['src', 'href', 'xlink:href', 'action', 'data', 'poster']);

export function sanitizeBookHtml(rawHtml: string): DocumentFragment {
  const purify = DOMPurify(window);
  purify.addHook('uponSanitizeAttribute', (_node, data) => {
    if (URI_ATTRS.has(data.attrName) && !ALLOWED_URI_REGEXP.test(data.attrValue)) {
      data.forceKeepAttr = false;
      data.attrValue = '';
    }
  });
  const fragment = purify.sanitize(rawHtml, {
    RETURN_DOM_FRAGMENT: true,
    FORBID_TAGS,
    FORBID_ATTR,
    ALLOW_DATA_ATTR: false,
    ALLOWED_URI_REGEXP,
  }) as DocumentFragment;
  purify.removeAllHooks();
  return fragment;
}
