use hnsw_rs::hnsw::Hnsw;
use hnsw_rs::hnswio::{HnswIo, ReloadOptions};
use hnsw_rs::prelude::*;
use serde::{Deserialize, Serialize};

use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock};

#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
pub struct Vector {
    pub id: u64,
    pub vector: Vec<f32>,
}

impl Vector {
    pub fn new(id: u64, vector: Vec<f32>) -> Self {
        Self { id, vector }
    }
}
#[derive(Serialize, Deserialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub id: u64,
    pub distance: f32,
}

impl SearchResult {
    pub fn new(id: u64, distance: f32) -> Self {
        Self { id, distance }
    }
}
pub struct VectorStore {
    pub dim: usize,
    pub directory: PathBuf,
    pub basename: String,
    pub ef_search: usize,
    pub is_initialized: bool,
    pub add_vector_queue: Vec<Vec<Vector>>,
}

impl VectorStore {
    pub fn new() -> anyhow::Result<Self> {
        Ok(Self {
            dim: 0,
            directory: PathBuf::from(""),
            is_initialized: false,
            basename: "".to_string(),
            ef_search: 50, // Default ef_search parameter
            add_vector_queue: Vec::new(),
        })
    }
    pub fn init(&mut self, directory: PathBuf, dim: usize, basename: &str) -> anyhow::Result<()> {
        fs::create_dir_all(&directory)?;
        self.directory = directory;

        self.dim = dim;
        self.basename = basename.to_string();
        self.is_initialized = true;
        Ok(())
    }

    /// Get the full path to the data file (for checking existence)
    // fn data_file_path(&self) -> PathBuf {
    //     self.directory.join(format!("{}.hnsw.data", self.basename))
    // }

    /// Helper function to create a new empty HNSW index
    fn create_new_index<'a>() -> Hnsw<'a, f32, DistL2> {
        let max_elements = 1_000_000;
        let max_nb_connection = 16;
        let max_layer = 16;
        let ef_construction = 200;
        Hnsw::new(
            max_nb_connection,
            max_elements,
            max_layer,
            ef_construction,
            DistL2 {},
        )
    }

    pub fn check_is_initialized(&self) -> anyhow::Result<()> {
        if !self.is_initialized {
            anyhow::bail!("Vector store is not initialized");
        }
        Ok(())
    }

    /// Execute a closure with a loaded (or freshly created) HNSW index, keeping the reloader alive.
    fn with_hnsw_mut<F, R>(
        directory: &Path,
        basename: &str,
        mmap: bool,
        mut f: F,
    ) -> anyhow::Result<R>
    where
        F: FnMut(&mut Hnsw<f32, DistL2>) -> anyhow::Result<R>,
    {
        fs::create_dir_all(&directory)?;
        if Self::data_file_exists(directory, basename) {
            let mut reloader = HnswIo::new(directory, basename);
            let options = ReloadOptions::default().set_mmap(mmap);
            reloader.set_options(options);
            let mut hnsw = reloader
                .load_hnsw::<f32, DistL2>()
                .map_err(|e| anyhow::anyhow!("Failed to load HNSW index: {}", e))?;
            f(&mut hnsw)
        } else {
            let mut hnsw = Self::create_new_index();
            f(&mut hnsw)
        }
    }
    pub fn add_vectors(&mut self, vectors: Vec<Vector>) -> anyhow::Result<()> {
        self.add_vector_queue.push(vectors);
        self.process_vectors()?;
        Ok(())
    }
    /// Add a new vector to the store.
    /// id must be unique — you manage this externally.
    pub fn process_vectors(&mut self) -> anyhow::Result<()> {
        // remove the first 5 vectors from the queue and process them
        if self.add_vector_queue.is_empty() {
            return Ok(());
        }
        let vectors = self
            .add_vector_queue
            .drain(..std::cmp::min(5, self.add_vector_queue.len()))
            .flatten()
            .collect::<Vec<_>>();

        if vectors.iter().any(|v| v.vector.len() != self.dim) {
            anyhow::bail!("Vector has wrong dimension: expected {}", self.dim,);
        }
        self.check_is_initialized()?;
        // Extract directory and basename to avoid borrow checker issues
        let directory = self.directory.clone();
        let basename = self.basename.clone();

        let dump_name = Self::with_hnsw_mut(&directory, &basename, true, |hnsw| {
            // Insert the vectors
            for vector in &vectors {
                hnsw.insert((&vector.vector, vector.id as usize));
            }

            hnsw.file_dump(&directory, &basename)
                .map_err(|e| anyhow::anyhow!("Failed to save HNSW index: {}", e))
        })?;
        let mut old_basename = self.basename.clone();

        self.overwrite_old_dump(&mut old_basename, &dump_name)?;

        self.process_vectors()?;

        Ok(())
    }
    pub fn overwrite_old_dump(
        &mut self,
        old_basename: &str,
        new_dump_name: &str,
    ) -> anyhow::Result<()> {
        if old_basename == new_dump_name {
            return Ok(());
        }
        let directory = self.directory.clone();
        let old_dump_path = directory.join(format!("{}.hnsw.data", old_basename));
        let old_graph_path = directory.join(format!("{}.hnsw.graph", old_basename));

        let new_dump_path = directory.join(format!("{}.hnsw.data", new_dump_name));
        let new_graph_path = directory.join(format!("{}.hnsw.graph", new_dump_name));
        if !old_dump_path.exists() {
            return Ok(());
        }

        fs::rename(new_dump_path, old_dump_path)?;
        if !old_graph_path.exists() {
            return Ok(());
        }
        fs::rename(new_graph_path, old_graph_path)?;

        Ok(())
    }

    /// Helper to check if data file exists
    fn data_file_exists(directory: &Path, basename: &str) -> bool {
        directory.join(format!("{}.hnsw.data", basename)).exists()
    }

    /// Search the top-k nearest vectors
    pub fn search(&self, query: Vec<f32>, k: usize) -> anyhow::Result<Vec<SearchResult>> {
        if query.len() != self.dim {
            anyhow::bail!(
                "Query vector has wrong dimension: expected {}, got {}",
                self.dim,
                query.len()
            );
        }
        self.check_is_initialized()?;
        // Extract directory and basename to avoid borrow checker issues
        let directory = self.directory.clone();
        let basename = self.basename.clone();
        let ef_search = self.ef_search;

        // Load or create the index and perform search while the reloader stays alive.
        let neighbours = Self::with_hnsw_mut(&directory, &basename, true, |hnsw| {
            Ok(hnsw.search(&query, k, ef_search))
        })?;

        // Convert Vec<Neighbour> to Vec<(u32, f32)>
        let results = neighbours
            .into_iter()
            .map(|n| SearchResult::new(n.d_id as u64, n.distance))
            .collect::<Vec<_>>();

        Ok(results)
    }

    /// Set the ef_search parameter (default is 64)
    pub fn set_ef_search(&mut self, ef_search: usize) {
        self.ef_search = ef_search;
    }
}

// let mut vector_store = Arc::new(Mutex::new(VectorStore::new()));

static VECTOR_STORE: OnceLock<Arc<Mutex<VectorStore>>> = OnceLock::new();

pub fn vector_store() -> &'static Arc<Mutex<VectorStore>> {
    VECTOR_STORE.get_or_init(|| {
        Arc::new(Mutex::new(
            VectorStore::new().expect("Failed to create VectorStore"),
        ))
    })
}

fn init_vector_store(
    app_data_dir: PathBuf,
    dim: usize,
    name: &str,
) -> anyhow::Result<MutexGuard<'static, VectorStore>> {
    let mut vectorstore = vector_store()
        .lock()
        .map_err(|e| anyhow::anyhow!("Failed to lock vector store: {}", e))?;
    vectorstore
        .init(app_data_dir, dim, name)
        .map_err(|e| anyhow::anyhow!("Failed to initialize vector store: {}", e))?;
    Ok(vectorstore)
}
pub fn save_vectors(
    vectors: Vec<Vector>,
    app_data_dir: PathBuf,
    dim: usize,
    name: &str,
) -> anyhow::Result<()> {
    let mut vectorstore = init_vector_store(app_data_dir, dim, name)?;

    vectorstore
        .add_vectors(vectors)
        .map_err(|e| anyhow::anyhow!("Failed to add vectors: {}", e))?;
    Ok(())
}

pub fn search_vectors(
    app_data_dir: PathBuf,
    dim: usize,
    name: &str,
    query: Vec<f32>,
    k: usize,
) -> anyhow::Result<Vec<SearchResult>> {
    let vectorstore = init_vector_store(app_data_dir, dim, name)?;

    let res = vectorstore
        .search(query, k)
        .map_err(|e| anyhow::anyhow!("Failed to search vectors: {}", e))?;
    Ok(res)
}
