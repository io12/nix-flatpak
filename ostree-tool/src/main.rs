use std::io::{Read, Write};
use std::os::unix::prelude::PermissionsExt;
use std::path::{Path, PathBuf};

use gvariant::Marker;
use gvariant::{gv, Structure};
use json::JsonValue;

#[derive(clap::Parser)]
struct Args {
    #[clap(subcommand)]
    action: Action,
}

#[derive(clap::Subcommand)]
enum Action {
    Parse {
        #[clap(value_enum)]
        object_type: ObjectType,
    },
    UnzipFilez,
    RealizeFile {
        path: PathBuf,
    },
    ShowDeployFile,
    MakeDeployFile {
        origin: String,
        commit: String,
    },
}

#[derive(clap::ValueEnum, Copy, Clone)]
enum ObjectType {
    Commit,
    Dirtree,
}

impl Action {
    fn run(&self, data: &[u8]) {
        match self {
            Action::Parse { object_type } => parse(data, *object_type),
            Action::UnzipFilez => unzip_filez(data),
            Action::RealizeFile { path } => realize_file(data, path),
            Action::ShowDeployFile => show_deploy_file(data),
            Action::MakeDeployFile { origin, commit } => make_deploy_file(origin, commit),
        }
    }
}

impl ObjectType {
    fn parse_object(self, data: &[u8]) -> JsonValue {
        match self {
            ObjectType::Commit => parse_commit(data),
            ObjectType::Dirtree => parse_dirtree(data),
        }
    }
}

fn parse_commit(data: &[u8]) -> JsonValue {
    let data = gv!("(a{sv}aya(say)sstayay)").from_bytes(data);
    let (_, _, _, _, _, _, dirtree, dirmeta) = data.to_tuple();
    json::object! {
        dirtree: hex::encode(dirtree),
        dirmeta: hex::encode(dirmeta),
    }
}

fn parse_dirtree(data: &[u8]) -> JsonValue {
    let data = gv!("(a(say)a(sayay))").from_bytes(data);
    let (files, dirs) = data.to_tuple();
    let files = files
        .into_iter()
        .map(|file| {
            let (name, hash) = file.to_tuple();
            json::object! {
                name: name.to_str(),
                hash: hex::encode(hash),
            }
        })
        .collect::<Vec<JsonValue>>();
    let dirs = dirs
        .into_iter()
        .map(|dir| {
            let (name, dirtree, dirmeta) = dir.to_tuple();
            json::object! {
                name: name.to_str(),
                dirtree: hex::encode(dirtree),
                dirmeta: hex::encode(dirmeta),
            }
        })
        .collect::<Vec<JsonValue>>();
    json::object! {
        files: files,
        dirs: dirs,
    }
}

fn parse(data: &[u8], object_type: ObjectType) {
    let object = object_type.parse_object(data);
    std::io::stdout()
        .write_all(object.to_string().as_bytes())
        .unwrap();
}

fn unzip_filez(data: &[u8]) {
    let header_size = u32::from_be_bytes(data[..4].try_into().unwrap()) as usize;
    let header_start = 8;
    let header_end = header_start + header_size;
    let header = &data[header_start..header_end];

    let header = gv!("(tuuuusa(ayay))").from_bytes(header);
    let (_size, uid, gid, mode, rdev, symlink_target, xattrs) = header.to_tuple();
    let xattrs = xattrs
        .into_iter()
        .map(|attr| attr.to_tuple())
        .collect::<Vec<(&[u8], &[u8])>>();
    let new_header =
        gv!("(uuuusa(ayay))").serialize_to_vec(&(uid, gid, mode, rdev, symlink_target, &xattrs));

    let compressed_data = &data[header_end..];
    let decompressed_data = if compressed_data.is_empty() {
        Vec::new()
    } else {
        miniz_oxide::inflate::decompress_to_vec(compressed_data).unwrap()
    };

    let decompressed_file = (new_header.len() as u32)
        .to_be_bytes()
        .into_iter()
        .chain(0u32.to_be_bytes())
        .chain(new_header)
        .chain(decompressed_data)
        .collect::<Vec<u8>>();

    std::io::stdout().write_all(&decompressed_file).unwrap();
}

fn realize_file(data: &[u8], path: &Path) {
    let header_size = u32::from_be_bytes(data[..4].try_into().unwrap()) as usize;
    let header_start = 8;
    let header_end = header_start + header_size;
    let header = &data[header_start..header_end];

    let header = gv!("(uuuusa(ayay))").from_bytes(header);
    let (_uid, _gid, mode, _rdev, symlink_target, xattrs) = header.to_tuple();

    let mode = u32::from_be(*mode);
    let symlink_target = symlink_target.to_str();
    let content = &data[header_end..];

    if symlink_target.is_empty() {
        std::fs::write(path, content).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    } else {
        std::os::unix::fs::symlink(symlink_target, path).unwrap();
    }

    assert!(xattrs.is_empty());
}

macro_rules! deploy_variant_marker {
    () => {
        gv!("(ssasta{sv})")
    };
}

fn show_deploy_file(data: &[u8]) {
    let data = deploy_variant_marker!().from_bytes(data);
    println!("{:#?}", data);
}

macro_rules! to_variant {
    ($ty:literal,$v:expr) => {
        &*gv!("v").from_bytes(gv!("v").serialize_to_vec(gvariant::VariantWrap(gv!($ty), $v)))
    };
}

fn make_deploy_file(origin: &str, commit: &str) {
    let data = deploy_variant_marker!().serialize_to_vec(&(
        origin,
        commit,
        &[] as &[&str],
        0,
        [
            &("appdata-name", to_variant!("s", "")),
            &("deploy-version", to_variant!("i", 4)),
            &("appdata-license", to_variant!("s", "")),
            &("appdata-summary", to_variant!("s", "")),
            &("appdata-timestamp", to_variant!("i", 0)),
            &("previous-ids", to_variant!("as", &[] as &[&str])),
        ],
    ));
    std::io::stdout().write_all(&data).unwrap();
}

fn main() {
    let args = <Args as clap::Parser>::parse();
    let data = {
        let mut data = Vec::new();
        std::io::stdin().read_to_end(&mut data).unwrap();
        data
    };
    args.action.run(&data);
}
