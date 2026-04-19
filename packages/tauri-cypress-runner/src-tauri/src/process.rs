use std::collections::HashMap;
use std::process::{Child, Command, Stdio};
use log::{info, error};

pub struct AppProcess {
    child: Option<Child>,
}

impl AppProcess {
    pub fn new() -> Self {
        Self { child: None }
    }

    pub fn spawn(&mut self, binary_path: &str, env: &HashMap<String, String>) -> Result<u32, String> {
        self.kill().ok();
        let mut cmd = Command::new(binary_path);
        cmd.stdout(Stdio::piped()).stderr(Stdio::piped());
        for (key, value) in env {
            cmd.env(key, value);
        }
        let child = cmd.spawn().map_err(|e| format!("Failed to spawn {}: {}", binary_path, e))?;
        let pid = child.id();
        info!("Spawned app-under-test (pid: {})", pid);
        self.child = Some(child);
        Ok(pid)
    }

    pub fn kill(&mut self) -> Result<(), String> {
        if let Some(ref mut child) = self.child {
            child.kill().map_err(|e| e.to_string())?;
            child.wait().map_err(|e| e.to_string())?;
            info!("Killed app-under-test");
            self.child = None;
        }
        Ok(())
    }

    pub fn is_running(&mut self) -> bool {
        if let Some(ref mut child) = self.child {
            matches!(child.try_wait(), Ok(None))
        } else {
            false
        }
    }
}

impl Drop for AppProcess {
    fn drop(&mut self) {
        if let Err(e) = self.kill() {
            error!("Failed to kill app on drop: {}", e);
        }
    }
}
