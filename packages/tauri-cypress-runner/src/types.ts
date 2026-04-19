export interface TestFile { path: string; name: string; last_modified: number; }
export interface RunnerConfig { tauri_dir: string; build_command: string; binary_path: string; spec_pattern: string; control_port: number; default_command_timeout: number; exec_timeout: number; screenshots_folder: string; snapshots_folder: string; env: Record<string, string>; }
export interface TestRunnerResult { test_id: string; status: "passed" | "failed" | "skipped"; assertions: AssertionResult[]; error: string | null; duration_ms: number; }
export interface AssertionResult { description: string; passed: boolean; expected: unknown; actual: unknown; }
export interface IpcLogEntry { command: string; args: unknown; response: unknown; mocked: boolean; duration_ms: number; timestamp_ms: number; }
export interface DomSnapshot { label: string; html: string; screenshot?: string; url: string; timestamp_ms: number; command_name?: string; }
export interface CommandEntry { name: string; status: "pending" | "running" | "passed" | "failed"; snapshotIndex: number; duration?: number; error?: string; }
export interface BuildOutput { line: string; stream: "stdout" | "stderr"; }
export interface BuildComplete { success: boolean; exit_code: number | null; }
export interface DiffResult {
  baseline_path: string;
  actual_path: string;
  diff_path: string | null;
  match_percentage: number;
  dimensions: [number, number];
  diff_pixel_count: number;
  passed: boolean;
  threshold: number;
}
