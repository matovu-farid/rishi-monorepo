import type { JSX } from "react";
import { MoonLoader } from "react-spinners";

interface LoaderProps {
  isLoading?: boolean;
  color?: string;
}
export default function Loader({
  isLoading = true,
  color = "#36d7b7",
}: LoaderProps): JSX.Element {
  return (
    <div className="w-full h-full grid place-items-center">
      <MoonLoader
        color={color}
        loading={isLoading}
        size={50}
        aria-label="Loading Spinner"
        data-testid="loader"
      />
    </div>
  );
}
