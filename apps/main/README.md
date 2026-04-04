# Rishi

A cross-platform EPUB and PDF reader with offline-friendly Text-to-Speech (TTS), built with Tauri.

## Features

- **Library management**: Add books via file picker or drag-and-drop; persistent storage; delete from library
- **Reading progress**: Auto-saves and resumes per book
- **Text-to-Speech (TTS)**: Play/pause/stop, previous/next paragraph, background generation queue, local audio cache (provider-agnostic)
- **Themes**: Multiple reader themes (light/dark variants)
- **Navigation**: Keyboard arrows and touch swipe; table of contents for EPUB
- **EPUB reader**: Continuous layout with customizable styles
- **PDF reader**: Single/dual-page viewing, outline navigation, selectable text layer
- **Cross-platform**: macOS, Windows, and Linux

## Demo

Watch the app in action: [YouTube demo](https://youtu.be/vcWcpEGsof8)

## Screenshots

### Library View

![Rishi Library](./screenshots/library.png)

### Reading View

![Rishi Book Reader](./screenshots/book.png)

## Supported Formats

- `.epub`
- `.pdf`

## Usage

1. Open the app and add books using the Add button (file picker) or drag-and-drop `.epub`/`.pdf` files into the window
2. Select a book from the library to start reading; progress is saved automatically
3. Use the TTS controls at the bottom of the reader to listen to the current paragraph and navigate between paragraphs

## Building from Source

This guide will help you build Rishi from source for your operating system.

### Prerequisites

#### Installing Bun

Bun is required to build this project. Follow the instructions for your operating system:

##### macOS & Linux

Open your terminal and run:

```bash
curl -fsSL https://bun.com/install | bash
```

After installation, verify it was successful:

##### Windows

Open PowerShell and run:

```powershell
powershell -c "irm bun.com/install.ps1|iex"
```

After installation, verify it was successful:

```bash
bun --version
```

**Troubleshooting:** If you see a "command not found" error after installation, you may need to manually add Bun to your PATH. See the [Bun installation documentation](https://bun.com/docs/installation) for detailed instructions.

### Building the Application

Once Bun is installed, navigate to the project directory and run:

```bash
bunx tauri build
```

This will create platform-specific installers in the `src-tauri/target/release/bundle/` directory.

---

## For Developers

If you're looking to contribute or develop this project, please see [DEVELOPERS.md](./DEVELOPERS.md) for development setup and instructions.

---

#### Build Output Locations

- **macOS**: `.dmg` and `.app` files in `src-tauri/target/release/bundle/dmg/` and `src-tauri/target/release/bundle/macos/`
- **Windows**: `.msi` and `.exe` files in `src-tauri/target/release/bundle/msi/` and `src-tauri/target/release/bundle/nsis/`
- **Linux**: `.deb`, `.AppImage`, and other formats in `src-tauri/target/release/bundle/`

### Additional Resources

- [Bun Documentation](https://bun.com/docs)
- [Tauri Documentation](https://tauri.app/)

---

## License

See LICENSE file for details.
