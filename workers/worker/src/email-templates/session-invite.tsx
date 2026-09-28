/** @jsxImportSource react */
import {
  Body,
  Button,
  Container,
  Head,
  Heading,
  Hr,
  Html,
  Img,
  Link,
  Preview,
  Section,
  Text,
} from "@react-email/components";
import { render } from "@react-email/render";

const RISHI_ICON_URL = "https://rishi.fidexa.org/brand/rishi-icon.png";

type SessionInviteProps = {
  bookTitle?: string;
  shareUrl: string;
};

function invitationBookTitle(title?: string): string {
  return title?.replace(/\s+/g, " ").trim() || "A book on Rishi";
}

function SessionInviteEmail({ bookTitle, shareUrl }: Required<SessionInviteProps>) {
  return (
    <Html lang="en">
      <Head />
      <Preview>Read {bookTitle} together on Rishi. Your invitation is ready.</Preview>
      <Body style={{ margin: 0, padding: "32px 12px", backgroundColor: "#f8f5f1", fontFamily: "Arial, Helvetica, sans-serif", color: "#252320" }}>
        <Container style={{ maxWidth: 560, margin: "0 auto", padding: "36px 36px 32px", backgroundColor: "#ffffff", border: "1px solid #e9e1d9", borderRadius: 20 }}>
          <Section style={{ marginBottom: 36 }}>
            <Img src={RISHI_ICON_URL} alt="Rishi app icon" width="40" height="40" style={{ display: "inline-block", verticalAlign: "middle", borderRadius: 10 }} />
            <Text style={{ display: "inline-block", margin: "0 0 0 12px", verticalAlign: "middle", color: "#252320", fontSize: 20, fontWeight: 700, letterSpacing: "-0.5px" }}>
              Rishi
            </Text>
          </Section>

          <Text style={{ margin: "0 0 14px", color: "#a06c4d", fontSize: 11, fontWeight: 700, letterSpacing: "1.5px", textTransform: "uppercase" }}>
            Shared reading invitation
          </Text>
          <Heading as="h1" style={{ margin: "0 0 16px", color: "#252320", fontSize: 32, lineHeight: "39px", fontWeight: 700, letterSpacing: "-1px" }}>
            A good book is better together.
          </Heading>
          <Text style={{ margin: "0 0 28px", color: "#605b55", fontSize: 16, lineHeight: "25px" }}>
            You have been invited to a reading session in Rishi. Open the link below to join the group.
          </Text>

          <Section style={{ margin: "0 0 30px", padding: "20px 22px", backgroundColor: "#f8f5f1", borderLeft: "3px solid #a06c4d", borderRadius: 8 }}>
            <Text style={{ margin: "0 0 7px", color: "#8a6e5e", fontSize: 11, fontWeight: 700, letterSpacing: "1px", textTransform: "uppercase" }}>
              The book
            </Text>
            <Text style={{ margin: 0, color: "#252320", fontSize: 18, lineHeight: "26px", fontWeight: 700 }}>
              {bookTitle}
            </Text>
          </Section>

          <Section style={{ margin: "0 0 32px" }}>
            <Button href={shareUrl} style={{ display: "inline-block", padding: "15px 25px", backgroundColor: "#252320", borderRadius: 10, color: "#ffffff", fontSize: 15, fontWeight: 700, textDecoration: "none" }}>
              Join reading session
            </Button>
          </Section>

          <Hr style={{ margin: "0 0 22px", borderColor: "#eee9e4" }} />
          <Text style={{ margin: "0 0 8px", color: "#706a63", fontSize: 13, lineHeight: "20px" }}>
            Button not working? Copy this link into your browser:
          </Text>
          <Link href={shareUrl} style={{ color: "#80573f", fontSize: 13, lineHeight: "21px", textDecoration: "underline", wordBreak: "break-all" }}>
            {shareUrl}
          </Link>
          <Text style={{ margin: "27px 0 0", color: "#948d86", fontSize: 12, lineHeight: "19px" }}>
            If you weren’t expecting this invitation, you can ignore this email.
          </Text>
        </Container>
        <Container style={{ maxWidth: 560, margin: "0 auto", padding: "20px 12px", textAlign: "center" }}>
          <Text style={{ margin: 0, color: "#9b928a", fontSize: 12, lineHeight: "18px" }}>
            Rishi · Read together, wherever you are.
          </Text>
        </Container>
      </Body>
    </Html>
  );
}

export async function sessionInviteEmail({ bookTitle, shareUrl }: SessionInviteProps): Promise<{ subject: string; html: string; text: string }> {
  const title = invitationBookTitle(bookTitle);
  const subjectTitle = title.length > 70 ? `${title.slice(0, 67)}…` : title;
  return {
    subject: bookTitle?.trim() ? `Join me to read ${subjectTitle} on Rishi` : "Join my Rishi reading session",
    html: await render(<SessionInviteEmail bookTitle={title} shareUrl={shareUrl} />),
    text: `You're invited to a Rishi reading session.\n\nThe book: ${title}\n\nJoin reading session: ${shareUrl}\n\nIf you weren't expecting this invitation, you can ignore this email.`,
  };
}
