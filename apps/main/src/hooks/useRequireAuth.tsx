import { useCallback, useState } from 'react';
import { useAtomValue } from 'jotai';
import { isLoggedInAtom } from '@/components/pdf/atoms/user';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@components/components/ui/dialog';
import { Button } from '@components/components/ui/button';
import { LogIn } from 'lucide-react';
import { openUrl } from '@tauri-apps/plugin-opener';
import { getState } from '@/generated';

/**
 * Hook that gates premium features behind authentication.
 * Returns a `requireAuth` wrapper and a dialog element to render.
 *
 * Usage:
 *   const { requireAuth, AuthDialog } = useRequireAuth();
 *   // In handler: requireAuth(() => { ...premium action... });
 *   // In JSX: {AuthDialog}
 */
export function useRequireAuth() {
  const isLoggedIn = useAtomValue(isLoggedInAtom);
  const [open, setOpen] = useState(false);

  const requireAuth = useCallback(
    (action: () => void) => {
      if (isLoggedIn) {
        action();
      } else {
        setOpen(true);
      }
    },
    [isLoggedIn],
  );

  async function handleSignIn() {
    setOpen(false);
    const result = await getState();
    await openUrl(
      `https://rishi.fidexa.org?login=true&state=${encodeURIComponent(result.state)}&code_challenge=${encodeURIComponent(result.codeChallenge)}`,
    );
  }

  const AuthDialog = (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Sign in required</DialogTitle>
          <DialogDescription>
            This feature requires an account. Sign in to use AI-powered
            text-to-speech and book discussions.
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)}>
            Cancel
          </Button>
          <Button onClick={handleSignIn}>
            <LogIn size={16} className="mr-2" />
            Sign in
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );

  return { requireAuth, AuthDialog };
}
