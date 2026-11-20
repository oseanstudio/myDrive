use crate::model::Bookmark;
use std::{fs, io::Write, path::Path};

pub fn load(root: &Path) -> Result<Vec<Bookmark>, String> {
    let path = root.join("bookmarks.json");
    if !path.exists() {
        return Ok(vec![]);
    }
    serde_json::from_slice(&fs::read(path).map_err(|e| e.to_string())?)
        .map_err(|e| format!("Cannot read bookmarks; the original file has been preserved: {e}"))
}

pub fn save(root: &Path, bookmarks: &[Bookmark]) -> Result<(), String> {
    for b in bookmarks {
        b.validate()?;
    }
    let mut ids = std::collections::HashSet::new();
    if bookmarks.iter().any(|b| !ids.insert(&b.id)) {
        return Err("Duplicate bookmark ID.".into());
    }
    fs::create_dir_all(root).map_err(|e| e.to_string())?;
    let mut temp = tempfile::NamedTempFile::new_in(root).map_err(|e| e.to_string())?;
    temp.write_all(&serde_json::to_vec_pretty(bookmarks).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    temp.as_file().sync_all().map_err(|e| e.to_string())?;
    temp.persist(root.join("bookmarks.json"))
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn corrupt_store_is_not_silently_reset() {
        let d = tempfile::tempdir().unwrap();
        fs::write(d.path().join("bookmarks.json"), b"broken").unwrap();
        assert!(load(d.path()).is_err());
    }
    #[test]
    fn empty_store_roundtrip_and_replace() {
        let d = tempfile::tempdir().unwrap();
        save(d.path(), &[]).unwrap();
        save(d.path(), &[]).unwrap();
        assert!(load(d.path()).unwrap().is_empty());
    }
}
