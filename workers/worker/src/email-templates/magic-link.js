import { jsx as _jsx, jsxs as _jsxs } from "react/jsx-runtime";
/** @jsxImportSource react */
import { Body, Button, Container, Head, Heading, Html, Link, Preview, Section, Tailwind, Text, } from "@react-email/components";
import { render } from "@react-email/render";
/** React Email template for the magic-link sign-in flow. */
function MagicLinkEmail({ url }) {
    return (_jsxs(Html, { children: [_jsx(Head, {}), _jsx(Preview, { children: "Sign in to Rishi" }), _jsx(Tailwind, { children: _jsx(Body, { className: "bg-white font-sans", children: _jsxs(Container, { className: "mx-auto my-10 max-w-[520px] px-6", children: [_jsx(Heading, { className: "m-0 mb-6 text-[22px] font-bold text-gray-900", children: "Sign in to Rishi" }), _jsx(Text, { className: "m-0 text-[15px] leading-6 text-gray-700", children: "Click the button below to sign in. This link expires in 10 minutes." }), _jsx(Section, { className: "my-8", children: _jsx(Button, { href: url, className: "rounded-lg bg-gray-900 px-6 py-3 text-[15px] font-medium text-white no-underline", children: "Sign in to Rishi" }) }), _jsx(Text, { className: "m-0 text-[13px] leading-5 text-gray-500", children: "If the button doesn't work, paste this link in your browser:" }), _jsx(Link, { href: url, className: "text-[13px] leading-5 text-gray-500 break-all", children: url }), _jsx(Text, { className: "mt-8 text-[13px] leading-5 text-gray-500", children: "If you didn't request this, ignore this email." })] }) }) })] }));
}
/**
 * Render the React Email component to an HTML string.
 * Signature kept identical to the previous plain-HTML version so callers
 * (specifically `src/auth.ts`'s magic-link sendMagicLink) don't change.
 */
export async function magicLinkEmail({ url }) {
    return await render(_jsx(MagicLinkEmail, { url: url }));
}
