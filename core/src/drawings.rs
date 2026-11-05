//! Saved drawings: PNG snapshots of the screen with the user's pen strokes,
//! plus a small JSON sidecar, in `<data_dir>/drawings`.

use std::fs;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::conversation::now;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Drawing {
    pub id: String,
    pub title: String,
    pub created_at: u64,
    /// Absolute path of the PNG.
    #[serde(default)]
    pub path: String,
}

pub struct Drawings {
    dir: PathBuf,
}

impl Drawings {
    pub fn new(data_dir: &Path) -> Self {
        let dir = data_dir.join("drawings");
        let _ = fs::create_dir_all(&dir);
        Self { dir }
    }

    /// Stores a PNG and returns its record. Rejects data that is not a PNG.
    pub fn save(&self, png: &[u8], title: &str) -> std::io::Result<Drawing> {
        if !png.starts_with(b"\x89PNG\r\n\x1a\n") {
            return Err(std::io::Error::other("not a PNG"));
        }
        let id = uuid::Uuid::new_v4().to_string();
        let image = self.dir.join(format!("{id}.png"));
        fs::write(&image, png)?;
        let title = title.trim();
        let drawing = Drawing {
            id: id.clone(),
            title: if title.is_empty() {
                "Drawing".into()
            } else {
                title.chars().take(80).collect()
            },
            created_at: now(),
            path: image.to_string_lossy().into_owned(),
        };
        fs::write(
            self.dir.join(format!("{id}.json")),
            serde_json::to_vec_pretty(&drawing)?,
        )?;
        Ok(drawing)
    }

    /// Newest first. The path is recomputed so moved data folders still work.
    pub fn list(&self) -> Vec<Drawing> {
        let mut out: Vec<Drawing> = fs::read_dir(&self.dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter(|e| e.path().extension().is_some_and(|x| x == "json"))
            .filter_map(|e| serde_json::from_slice::<Drawing>(&fs::read(e.path()).ok()?).ok())
            .filter_map(|mut d| {
                let image = self.path(&d.id)?.with_extension("png");
                image.exists().then(|| {
                    d.path = image.to_string_lossy().into_owned();
                    d
                })
            })
            .collect();
        out.sort_by_key(|d| std::cmp::Reverse(d.created_at));
        out
    }

    pub fn delete(&self, id: &str) {
        if let Some(base) = self.path(id) {
            let _ = fs::remove_file(base.with_extension("png"));
            let _ = fs::remove_file(base.with_extension("json"));
        }
    }

    /// Only UUID-like ids map to files, so an id can never escape the folder.
    fn path(&self, id: &str) -> Option<PathBuf> {
        let ok = !id.is_empty()
            && id.len() <= 64
            && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
        ok.then(|| self.dir.join(format!("{id}.json")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn save_list_delete() {
        let dir = std::env::temp_dir().join(format!("cp-drawings-{}", uuid::Uuid::new_v4()));
        let d = Drawings::new(&dir);
        assert!(d.save(b"not png", "x").is_err());
        let png = b"\x89PNG\r\n\x1a\nrest";
        let saved = d.save(png, "  Sketch of the menu  ").unwrap();
        assert_eq!(saved.title, "Sketch of the menu");
        let listed = d.list();
        assert_eq!(listed, vec![saved.clone()]);
        assert_eq!(fs::read(&listed[0].path).unwrap(), png);
        d.delete(&saved.id);
        assert!(d.list().is_empty());
        d.delete("../../etc");
        let _ = fs::remove_dir_all(dir);
    }
}
