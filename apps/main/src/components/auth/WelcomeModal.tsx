import { useAtomValue, useSetAtom } from "jotai";
import { Sparkles, LogIn } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@components/components/ui/dialog";
import { Button } from "@components/components/ui/button";
import {
  showWelcomeModalAtom,
  setWelcomeSeenAtom,
  dismissWelcomeAtom,
} from "@/atoms/authPromo";
import { startSignInFlow } from "@/modules/auth";

/**
 * First-launch hero modal. Visible only when authHydrated && !isLoggedIn && !welcomeSeen.
 * Mounted once at the root level.
 */
export function WelcomeModal(): React.JSX.Element {
  const open = useAtomValue(showWelcomeModalAtom);
  const setWelcomeSeen = useSetAtom(setWelcomeSeenAtom);
  const dismissWelcome = useSetAtom(dismissWelcomeAtom);

  async function handleSignIn() {
    setWelcomeSeen();
    await startSignInFlow();
  }

  function handleMaybeLater() {
    dismissWelcome();
  }

  function handleOpenChange(next: boolean) {
    if (!next) dismissWelcome();
  }

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <div className="mx-auto mb-2 rounded-full bg-primary/10 p-3">
            <Sparkles size={28} className="text-primary" />
          </div>
          <DialogTitle className="text-center text-xl">
            Welcome to Rishi
          </DialogTitle>
          <DialogDescription className="pt-2 text-center">
            Sign in to unlock AI-powered text-to-speech, chat with your books,
            and sync your library across devices.
          </DialogDescription>
        </DialogHeader>

        <DialogFooter className="sm:justify-center">
          <Button variant="outline" onClick={handleMaybeLater}>
            Maybe later
          </Button>
          <Button onClick={handleSignIn}>
            <LogIn size={16} className="mr-2" />
            Sign in
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
