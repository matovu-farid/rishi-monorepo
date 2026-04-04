import { open } from "@tauri-apps/plugin-dialog";

export async function chooseFiles() {
  const filePaths = await open({
    multiple: true,
    directory: false,
    filters: [{ name: "EPUB Books", extensions: ["epub"] }, { name: "PDF Files", extensions: ["pdf"] }],
  });

  return filePaths || []; // Returns real absolute paths
}
