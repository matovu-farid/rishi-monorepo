import { useState } from "react";

export const useWindowSize = () => {
  const [windowSize] = useState({
    width: typeof window !== "undefined" ? window.innerWidth : 1024,
    height: typeof window !== "undefined" ? window.innerHeight : 768,
  });
  return windowSize;
};