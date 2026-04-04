import FileDrop from "@components/FileComponent";
import { createLazyFileRoute } from "@tanstack/react-router";
import { motion } from "framer-motion";

export const Route = createLazyFileRoute("/")({
  component: Index,
});

function Index() {
  return (
    <motion.div layout className="grid place-items-center h-screen">
      <FileDrop />
    </motion.div>
  );
}
