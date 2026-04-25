import React from "react";

interface SpinnerProps {
  size?: "small" | "medium" | "large";
  color?: string;
}

const sizeMap = {
  small: 16,
  medium: 24,
  large: 36,
};

export const Spinner: React.FC<SpinnerProps> = ({
  size = "medium",
  color = "currentColor",
}) => {
  const px = sizeMap[size];
  return (
    <svg
      width={px}
      height={px}
      viewBox="0 0 24 24"
      fill="none"
      className="animate-spin"
    >
      <circle
        cx="12"
        cy="12"
        r="10"
        stroke={color}
        strokeWidth="3"
        strokeLinecap="round"
        strokeDasharray="31.42 31.42"
        opacity="0.25"
      />
      <circle
        cx="12"
        cy="12"
        r="10"
        stroke={color}
        strokeWidth="3"
        strokeLinecap="round"
        strokeDasharray="31.42 31.42"
        strokeDashoffset="62.83"
        opacity="0.75"
      />
    </svg>
  );
};
