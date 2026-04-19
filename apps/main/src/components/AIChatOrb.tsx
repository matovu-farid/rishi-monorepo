import React from "react";

interface AIChatOrbProps {
  isProcessing: boolean;
  onClick: () => void;
}

const barHeights = [8, 14, 20, 12];

const glassContainer: React.CSSProperties = {
  background:
    "linear-gradient(135deg, rgba(255,255,255,0.30) 0%, rgba(255,255,255,0.12) 40%, rgba(200,210,230,0.16) 100%)",
  backdropFilter: "blur(40px) saturate(180%)",
  WebkitBackdropFilter: "blur(40px) saturate(180%)",
  border: "1px solid rgba(255,255,255,0.45)",
  boxShadow:
    "0 4px 24px rgba(0,0,0,0.18), 0 1px 6px rgba(0,0,0,0.12), inset 0 0 0 0.5px rgba(255,255,255,0.3), inset 0 1px 0 rgba(255,255,255,0.5)",
};

export default function AIChatOrb({ isProcessing, onClick }: AIChatOrbProps) {
  return (
    <>
      <style>{`
        @keyframes ai-waveform {
          0%, 100% { transform: scaleY(0.4); }
          50% { transform: scaleY(1); }
        }
        @media (prefers-reduced-motion: reduce) {
          @keyframes ai-waveform {
            0%, 50%, 100% { transform: scaleY(0.7); }
          }
        }
      `}</style>

      <div
        onClick={onClick}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            onClick();
          }
        }}
        role="button"
        tabIndex={0}
        aria-label="Toggle AI chat"
        className="fixed z-50 flex items-center justify-center cursor-pointer"
        style={{
          ...glassContainer,
          top: "50%",
          left: "50%",
          transform: "translate(-50%, -50%)",
          width: 52,
          height: 52,
          borderRadius: "50%",
        }}
      >
        <div className="flex items-center gap-[3px]">
          {barHeights.map((h, i) => (
            <div
              key={i}
              style={{
                width: 3,
                height: h,
                borderRadius: 1.5,
                backgroundColor: "rgba(88, 86, 214, 0.70)",
                transformOrigin: "center",
                animation: isProcessing
                  ? `ai-waveform 1.2s ease-in-out ${i * 0.15}s infinite`
                  : "none",
              }}
            />
          ))}
        </div>
      </div>
    </>
  );
}
