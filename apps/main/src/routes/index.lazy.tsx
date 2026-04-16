import FileDrop from "@components/FileComponent";
import { UpdateMenu } from "@components/UpdateMenu";
import { createLazyFileRoute } from "@tanstack/react-router";
import { motion } from "framer-motion";

export const Route = createLazyFileRoute("/")({
  component: Index,
});

function Index() {
  return (
    <motion.div layout className="grid place-items-center h-screen relative">
      <div className="absolute right-4 top-4 z-10">
        <UpdateMenu />
      </div>
      <FileDrop />
    </motion.div>
  );
}
