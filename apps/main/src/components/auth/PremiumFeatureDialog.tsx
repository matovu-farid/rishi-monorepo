import { LogIn, Check, Loader2 } from "lucide-react";
import { useAuthStore } from "@/stores/authStore";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@components/components/ui/dialog";
import { Button } from "@components/components/ui/button";
import { startSignInFlow } from "@/modules/auth";
import { PREMIUM_FEATURES, type PremiumFeature } from "./features";

export interface PremiumFeatureDialogProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  feature: PremiumFeature;
}

export function PremiumFeatureDialog({
  open,
  onOpenChange,
  feature,
}: PremiumFeatureDialogProps): React.JSX.Element {
  const config = PREMIUM_FEATURES[feature];
  const Icon = config.icon;
  const signingIn = useAuthStore((s) => s.signingIn);

  async function handleSignIn() {
    onOpenChange(false);
    await startSignInFlow();
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent>
        <DialogHeader>
          <div className="flex items-center gap-3">
            <div className="rounded-full bg-primary/10 p-2">
              <Icon size={20} className="text-primary" />
            </div>
            <DialogTitle>{config.title}</DialogTitle>
          </div>
          <DialogDescription className="pt-2">
            {config.description}
          </DialogDescription>
        </DialogHeader>

        {config.bullets.length > 0 && (
          <ul className="mt-2 space-y-2 text-sm">
            {config.bullets.map((b) => (
              <li key={b} className="flex items-start gap-2">
                <Check size={16} className="mt-0.5 shrink-0 text-primary" />
                <span>{b}</span>
              </li>
            ))}
          </ul>
        )}

        <DialogFooter>
          <Button variant="outline" onClick={() => onOpenChange(false)}>
            Maybe later
          </Button>
          <Button onClick={handleSignIn} disabled={signingIn}>
            {signingIn ? <Loader2 size={16} className="mr-2 animate-spin" /> : <LogIn size={16} className="mr-2" />}
            {signingIn ? "Signing in…" : "Sign in"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
