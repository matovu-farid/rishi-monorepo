# Developer Guide

This guide covers how to set up your development environment and run Rishi in development mode.

## Prerequisites

### Installing Bun

Bun is required for development. Follow the instructions for your operating system:

#### macOS & Linux

Open your terminal and run:

```bash
curl -fsSL https://bun.com/install | bash
```

After installation, verify it was successful:

```bash
bun --version
```

**Adding Bun to PATH (if needed):**

If you see a "command not found" error, add Bun to your PATH:

1. Determine your shell:

   ```bash
   echo $SHELL
   ```

2. Add to your shell configuration file:
   - For bash: Add to `~/.bashrc`
   - For zsh: Add to `~/.zshrc`
   - For fish: Add to `~/.config/fish/config.fish`

   Add these lines:

   ```bash
   export BUN_INSTALL="$HOME/.bun"
   export PATH="$BUN_INSTALL/bin:$PATH"
   ```

3. Reload your shell:
   ```bash
   source ~/.bashrc  # or ~/.zshrc
   ```

#### Windows

Open PowerShell and run:

```powershell
powershell -c "irm bun.com/install.ps1|iex"
```

After installation, verify it was successful:

```powershell
bun --version
```

**Adding Bun to PATH (if needed):**

If you see a "command not found" error:

1. Open System Properties (search "Environment Variables" in Start Menu)
2. Click "Environment Variables"
3. Under "User variables", find and edit "Path"
4. Add the Bun installation directory: `%USERPROFILE%\.bun\bin`
5. Click OK and restart your terminal

### Additional Prerequisites

#### Rust

Tauri requires Rust. Install it from [rustup.rs](https://rustup.rs/):

**macOS & Linux:**

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

**Windows:**
Download and run the installer from [rustup.rs](https://rustup.rs/)

#### Platform-Specific Requirements

**macOS:**

- Xcode Command Line Tools: `xcode-select --install`

**Linux:**

- Build essentials:
  ```bash
  sudo apt update
  sudo apt install libwebkit2gtk-4.0-dev \
    build-essential \
    curl \
    wget \
    file \
    libssl-dev \
    libgtk-3-dev \
    libayatana-appindicator3-dev \
    librsvg2-dev
  ```

**Windows:**

- Microsoft Visual Studio C++ Build Tools
- WebView2 (usually pre-installed on Windows 10/11)

## Development Setup

1. **Clone the repository:**

   ```bash
   git clone <repository-url>
   cd rishi
   ```

2. **Install dependencies:**

   ```bash
   bun install
   ```

3. **Run in development mode:**
   ```bash
   bunx tauri dev
   ```

This will start the development server with hot-reload enabled. Any changes you make to the source code will automatically reload the application.

## Project Structure

- `src/` - Frontend React/TypeScript code
- `src-tauri/` - Rust backend code
- `src/components/` - React components
- `src/routes/` - Application routes
- `src/epubjs/` - EPUB rendering engine
- `src/modules/` - Core application modules

## Development Workflow

### Frontend Development

The frontend is built with:

- React
- TypeScript
- TanStack Router
- Vite

Make changes in the `src/` directory. The dev server will hot-reload your changes.

### Backend Development

The backend is built with Rust and Tauri. Make changes in `src-tauri/src/`. The application will restart automatically when you save.

### Building for Production

To create a production build:

```bash
bunx tauri build
```

The built application will be in `src-tauri/target/release/bundle/`.

## Useful Commands

- `bun install` - Install dependencies
- `bunx tauri dev` - Run development server
- `bunx tauri build` - Build production application
- `bun run dev` - Run frontend only (for UI development)
- `cargo test` - Run Rust tests (in `src-tauri/` directory)

## Debugging

### Frontend Debugging

Open the Developer Tools in the running application:

- **macOS**: `Cmd + Option + I`
- **Windows/Linux**: `Ctrl + Shift + I`

### Backend Debugging

Add logging in your Rust code:

```rust
println!("Debug message");
```

Or use the `log` crate for structured logging.

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Test thoroughly
5. Commit your changes: `git commit -am 'Add new feature'`
6. Push to the branch: `git push origin feature/my-feature`
7. Submit a Pull Request

## Resources

- [Bun Documentation](https://bun.com/docs)
- [Tauri Documentation](https://tauri.app/)
- [React Documentation](https://react.dev/)
- [TypeScript Documentation](https://www.typescriptlang.org/docs/)
- [Rust Book](https://doc.rust-lang.org/book/)

## Troubleshooting

### "Command not found: bun"

Make sure Bun is properly added to your PATH. See the installation instructions above.

### Build Errors on Linux

Ensure all system dependencies are installed. See the "Platform-Specific Requirements" section above.

### Tauri Build Fails

1. Ensure Rust is up to date: `rustup update`
2. Clear the target directory: `rm -rf src-tauri/target`
3. Try building again: `bunx tauri build`

### Hot Reload Not Working

1. Stop the dev server
2. Clear node_modules: `rm -rf node_modules`
3. Reinstall: `bun install`
4. Start dev server: `bunx tauri dev`

---

For user documentation, see the main [README.md](./README.md).
