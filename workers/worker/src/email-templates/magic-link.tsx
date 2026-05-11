/** @jsxImportSource react */
import {
  Body,
  Button,
  Container,
  Head,
  Heading,
  Html,
  Link,
  Preview,
  Section,
  Tailwind,
  Text,
} from "@react-email/components"
import { render } from "@react-email/render"

interface MagicLinkEmailProps {
  url: string
}

/** React Email template for the magic-link sign-in flow. */
function MagicLinkEmail({ url }: MagicLinkEmailProps) {
  return (
    <Html>
      <Head />
      <Preview>Sign in to Rishi</Preview>
      <Tailwind>
        <Body className="bg-white font-sans">
          <Container className="mx-auto my-10 max-w-[520px] px-6">
            <Heading className="m-0 mb-6 text-[22px] font-bold text-gray-900">
              Sign in to Rishi
            </Heading>
            <Text className="m-0 text-[15px] leading-6 text-gray-700">
              Click the button below to sign in. This link expires in 10 minutes.
            </Text>
            <Section className="my-8">
              <Button
                href={url}
                className="rounded-lg bg-gray-900 px-6 py-3 text-[15px] font-medium text-white no-underline"
              >
                Sign in to Rishi
              </Button>
            </Section>
            <Text className="m-0 text-[13px] leading-5 text-gray-500">
              If the button doesn't work, paste this link in your browser:
            </Text>
            <Link
              href={url}
              className="text-[13px] leading-5 text-gray-500 break-all"
            >
              {url}
            </Link>
            <Text className="mt-8 text-[13px] leading-5 text-gray-500">
              If you didn't request this, ignore this email.
            </Text>
          </Container>
        </Body>
      </Tailwind>
    </Html>
  )
}

/**
 * Render the React Email component to an HTML string.
 * Signature kept identical to the previous plain-HTML version so callers
 * (specifically `src/auth.ts`'s magic-link sendMagicLink) don't change.
 */
export async function magicLinkEmail({ url }: MagicLinkEmailProps): Promise<string> {
  return await render(<MagicLinkEmail url={url} />)
}
